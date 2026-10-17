import Foundation

/// Journalise les etapes critiques et capture la raison d'un crash.
///
/// Un crash Swift (dereferencement force, index hors bornes) leve un signal :
/// rien ne peut le rattraper, mais on peut noter la derniere etape executee
/// avant le plantage, ce qui suffit a localiser le probleme.
enum CrashLog {

    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let limit = 400

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.app.xgrab")?
            .appendingPathComponent("crash.log")
    }

    // -------------------------------------------------------------- installation

    /// A appeler au demarrage de l'app.
    static func install() {
        NSSetUncaughtExceptionHandler(xgrabExceptionHandler)

        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            signal(signalNumber, SIG_IGN)
            signal(signalNumber, xgrabSignalHandler)
        }
    }

    // ------------------------------------------------------------------ journal

    static func step(_ message: String) {
        let line = "\(Date().timeIntervalSince1970)  \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
        flush()
    }

    static func lastStep() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.last ?? "aucune"
    }

    static func dump() -> String {
        lock.lock()
        let copy = lines
        lock.unlock()
        return copy.joined(separator: "\n")
    }

    static func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        flush()
    }

    private static func flush() {
        guard let url = fileURL else { return }
        let text = dump()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Un gestionnaire d'exception doit etre une fonction C, sans contexte
/// capturant : d'ou ces deux fonctions globales.
private func xgrabExceptionHandler(_ exception: NSException) {
    CrashLog.step("EXCEPTION : \(exception.name.rawValue) - \(exception.reason ?? "?")")
}

private func xgrabSignalHandler(_ received: Int32) {
    // Dans un handler de signal on n'ecrit que des operations sures :
    // write() vers un descripteur, rien d'autre.
    let message = "SIGNAL \(received) apres \(CrashLog.lastStep())\n"
    message.withCString { pointer in
        _ = write(2, pointer, strlen(pointer))
    }
    signal(received, SIG_DFL)
    raise(received)
}
