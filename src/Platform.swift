// Files, locks, the log, the pair key's storage, the computer name, HTTP and detached processes.
import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

enum Env {
    static let vars = ProcessInfo.processInfo.environment
    static let defaultRelay = "https://omnia-relay.veldhub.workers.dev"
    static let keychainAccount = "pair-key"

    /// Local state lives here. `SESSIONS_HOME` overrides it (tests).
    static var home: URL {
        if let h = vars["SESSIONS_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omnia-sessions-plugin", isDirectory: true)
    }

    static func file(_ name: String) -> URL { home.appendingPathComponent(name) }

    /// detached (default): network work runs in its own process after the hook returns.
    /// inline: in the hook's process (tests). off: never (dry run; the store is still updated).
    static var sendMode: String { vars["SESSIONS_SEND"] ?? "detached" }

    /// Where a new pairing keeps K: the macOS Keychain when `security` exists, else a 0600 file.
    static var keyStore: String {
        if let s = vars["SESSIONS_KEY_STORE"], s == "file" || s == "keychain" { return s }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/security") ? "keychain" : "file"
    }

    static var keychainService: String {
        let s = vars["SESSIONS_KEYCHAIN_SERVICE"] ?? ""
        return s.isEmpty ? "studio.omnia.sessions.plugin" : s
    }

    /// `SESSIONS_RELAY` wins, then the relay used when pairing, then the default.
    /// Only https, or plain http to this computer (a local test relay).
    static func relayBase(paired: Paired?) -> String? {
        let fromEnv = vars["SESSIONS_RELAY"].flatMap { $0.isEmpty ? nil : $0 }
        var raw = fromEnv ?? paired?.relay ?? defaultRelay
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        if scheme == "https" { return raw }
        if scheme == "http", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) { return raw }
        return nil
    }

    static func computerName() -> String {
        #if canImport(SystemConfiguration)
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        #endif
        var name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { name.removeLast(6) }
        return name.isEmpty ? "Computer" : name
    }

    static var now: Int { Int(Date().timeIntervalSince1970) }
}

enum Files {
    static func ensureHome() {
        let path = Env.home.path
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }

    static func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// Write to a temporary file beside the target, then rename, so readers never see half a file.
    static func write(_ data: Data, to url: URL) throws {
        ensureHome()
        let tmp = url.path + ".tmp.\(getpid())"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp, url.path) != 0 {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func remove(_ url: URL) { unlink(url.path) }

    static func exists(_ url: URL) -> Bool { access(url.path, F_OK) == 0 }

    /// An empty 0600 file, made if it is not there: a mark.
    static func touch(_ url: URL) {
        ensureHome()
        let fd = open(url.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        if fd >= 0 { close(fd) }
    }
}

/// An advisory lock on a file, so hooks and the sender never write the same file at once.
final class FileLock {
    private var fd: Int32

    init?(_ url: URL, waitMs: Int) {
        Files.ensureHome()
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var waited = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if waited >= waitMs { close(fd); return nil }
            usleep(10_000)
            waited += 10
        }
        self.fd = fd
    }

    /// Call explicitly where the lock should end; Swift may release an unused object early.
    func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { unlock() }
}

enum Log {
    /// Failures go here, never to the terminal: ~/.omnia-sessions-plugin/log.txt, kept under about 256 KB.
    static func write(_ message: String) {
        Files.ensureHome()
        let url = Env.file("log.txt")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 256 * 1024 {
            let old = Env.file("log.1.txt")
            unlink(old.path)
            rename(url.path, old.path)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp) \(message)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(line)
            handle.closeFile()
        }
    }
}

/// Written when pairing succeeds; its presence means "paired". No key in it: only, until the box exists at the relay,
/// the pairing's one-time ticket, which lets this computer's first PUT make the box and nothing else.
struct Paired: Codable {
    var relay: String
    var mac: String
    var at: Int
    var keyStore: String
    var ticket: String? = nil

    static var url: URL { Env.file("paired.json") }

    static func load() -> Paired? {
        guard let data = Files.read(url) else { return nil }
        return try? JSONDecoder().decode(Paired.self, from: data)
    }

    func save() throws {
        try Files.write(try JSONEncoder().encode(self), to: Paired.url)
    }

    /// Unpairs this computer locally: the pairing, K (Keychain or file) and what was kept for the phone.
    /// Used by `unpair`, and by the sender when the relay says the phone disconnected (410).
    static func forget(keyStore: String) {
        Files.remove(url)
        KeyStore.delete(store: keyStore)
        let lock = FileLock(StoreFile.lockURL, waitMs: 1000)
        for name in ["sessions.json", "sent.json", Sender.unknownMark] { Files.remove(Env.file(name)) }
        lock?.unlock()
    }
}

/// K lives in the login Keychain through /usr/bin/security (so no app-access dialog ever appears,
/// including after plugin updates), or in a 0600 file where there is no Keychain.
enum KeyStore {
    static var fileURL: URL { Env.file("pair-key") }

    static func save(_ k: String, store: String) -> Bool {
        if store == "file" {
            return (try? Files.write(Data(k.utf8), to: fileURL)) != nil
        }
        // `security -i` reads the command from stdin, so K never appears in the process list.
        let line = "add-generic-password -U -s \"\(Env.keychainService)\" -a \"\(Env.keychainAccount)\" -l \"Sessions pair key\" -w \"\(k)\"\n"
        let (code, _) = Run.process("/usr/bin/security", ["-i"], stdin: Data(line.utf8))
        return code == 0 && load(store: store) == k
    }

    static func load(store: String) -> String? {
        if store == "file" {
            guard let data = Files.read(fileURL) else { return nil }
            let k = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return k.isEmpty ? nil : k
        }
        let (code, out) = Run.process("/usr/bin/security", ["find-generic-password", "-s", Env.keychainService, "-a", Env.keychainAccount, "-w"])
        guard code == 0 else { return nil }
        let k = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static func delete(store: String) {
        Files.remove(fileURL)
        if store == "keychain" {
            _ = Run.process("/usr/bin/security", ["delete-generic-password", "-s", Env.keychainService, "-a", Env.keychainAccount])
        }
    }
}

enum Run {
    /// Runs a program and returns its exit code and stdout. Used off the hook's fast path only.
    static func process(_ path: String, _ args: [String], stdin: Data? = nil) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try p.run() } catch { return (-1, Data()) }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            input.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Starts this tool again in its own session with stdin, stdout and stderr on /dev/null and no other
    /// inherited descriptors, so Claude Code is not kept waiting on its output and does not wait for it.
    static func detached(_ args: [String]) -> Bool {
        guard let first = CommandLine.arguments.first,
              let exe = first.hasPrefix("/") ? first : Bundle.main.executablePath else { return false }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, exe, &actions, &attr, argv, environ) == 0
    }
}

enum HTTP {
    /// One request with a hard time limit. Returns nil when the relay could not be reached in time.
    static func send(_ method: String, _ urlString: String, body: Data?, headers: [String: String],
                     timeout: TimeInterval) -> (status: Int, body: Data)? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("sessions-plugin/1", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 0.2) == .timedOut { return nil }
        return result
    }
}
