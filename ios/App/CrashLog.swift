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
        NSSetUncaughtExceptionHandler { exception in
            step("EXCEPTION : \(exception.name.rawValue) - \(exception.reason ?? "?")")
            flush()
        }

        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            signal(signalNumber, SIG_IGN)
            signal(signalNumber) { received in
                // Dans un handler de signal on n'ecrit que des operations
                // sures : write() vers un descripteur, rien d'autre.
                let message = "SIGNAL \(received) a \(CrashLog.lastStep())\n"
                message.withCString { pointer in
                    _ = write(2, pointer, strlen(pointer))
                }
                CrashLog.flush()
                signal(received, SIG_DFL)
                raise(received)
            }
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
