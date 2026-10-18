import Foundation

/// Journalise les etapes critiques et note la derniere avant un crash.
///
/// Un handler de signal ne peut appeler que des fonctions signal-safe :
/// ni verrou, ni allocation Swift. On tient donc une derniere-etape en
/// memoire brute, ecrite sans verrou, que le handler recopie telle quelle.
enum CrashLog {

    /// Tampon partage, ecrit sans verrou, reserve au handler de signal.
    nonisolated(unsafe) private static let buffer: UnsafeMutablePointer<CChar> = {
        let size = 256
        let pointer = UnsafeMutableRawPointer
            .allocate(byteCount: size, alignment: 1)
            .assumingMemoryBound(to: CChar.self)
        pointer.initialize(repeating: 0, count: size)
        return pointer
    }()

    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let limit = 400

    /// Le groupe partage quand il existe, sinon Documents : le journal doit
    /// fonctionner meme quand le conteneur n'est pas resolu.
    static var fileURL: URL? {
        if let shared = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.app.xgrab") {
            return shared.appendingPathComponent("crash.log")
        }
        return FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("crash.log")
    }

    // -------------------------------------------------------------- installation

    static func install() {
        NSSetUncaughtExceptionHandler(xgrabExceptionHandler)
        for number in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            signal(number, SIG_IGN)
            signal(number, xgrabSignalHandler)
        }
    }

    // ------------------------------------------------------------------ journal

    /// Copie brute, sans verrou ni allocation massive : le tampon ne sert
    /// qu'a etre lu depuis un handler de signal.
    private static func remember(_ text: String) {
        var offset = 0
        for byte in text.utf8.prefix(250) {
            buffer[offset] = CChar(bitPattern: byte)
            offset += 1
            if offset == 250 { break }
        }
        buffer[offset] = 0
    }

    static func step(_ message: String) {
        let line = "\(Date().timeIntervalSince1970)  \(message)"
        remember(line)
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
        flush()
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
        remember("journal efface")
        flush()
    }

    private static func flush() {
        guard let url = fileURL else { return }
        try? dump().write(to: url, atomically: true, encoding: .utf8)
    }

    /// Recopie le tampon vers un descripteur. Appele uniquement depuis un
    /// handler de signal : strlen et write sont signal-safe.
    static func emitBuffer(to descriptor: Int32) {
        let length = strlen(buffer)
        guard length > 0 else { return }
        buffer.withMemoryRebound(to: UInt8.self, capacity: 256) { raw in
            _ = write(descriptor, raw, length)
        }
    }
}

/// Gestionnaires sans contexte : l'API C exige un pointeur de fonction.
private func xgrabExceptionHandler(_ exception: NSException) {
    CrashLog.step("EXCEPTION \(exception.name.rawValue) : \(exception.reason ?? "?")")
}

/// Handler de signal minimal : write(2), puis on rend la main au systeme.
private func xgrabSignalHandler(_ received: Int32) {
    let banner = "XGRAB SIG\(received)\n"
    banner.withCString { pointer in
        _ = write(2, pointer, strlen(pointer))
    }
    CrashLog.emitBuffer(to: 2)

    signal(received, SIG_DFL)
    raise(received)
}