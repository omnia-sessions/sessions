// sessions-hook: the computer side of the Sessions iPhone app.
//
//   sessions-hook hook                 run by Claude Code's hooks (JSON on stdin); prints nothing, returns at once
//   sessions-hook pair <code>          pair with the phone using the six-digit code it shows
//   sessions-hook unpair               forget the phone and remove this computer's box at the relay
//   sessions-hook status               where things stand
//   sessions-hook send                 (internal) seal and send the state; started detached by `hook`
//   OMNIA_KEY=<K> sessions-hook seal|open   the relay's sealing, for tests (same as mac/omniacrypt)
//
// Environment: SESSIONS_RELAY (relay address), SESSIONS_HOME (state folder), SESSIONS_SEND (detached|inline|off),
// SESSIONS_KEY_STORE (keychain|file), SESSIONS_KEYCHAIN_SERVICE.
import CryptoKit
import Foundation

let version = "0.1.0"
let args = Array(CommandLine.arguments.dropFirst())

enum Hook {
    /// Never prints, never blocks on the network, always exits 0.
    static func run() -> Int32 {
        let input = isatty(0) == 0 ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        guard access(Paired.url.path, F_OK) == 0 else { return 0 }   // nothing paired: do nothing
        guard input.count < 4_000_000,
              let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { return 0 }
        let lock = FileLock(StoreFile.lockURL, waitMs: 1000)
        var store = StoreFile.load()
        let changed = Events.apply(event, to: &store, now: Env.now)
        if changed {
            do { try store.save() } catch { Log.write("hook: could not save the session store: \(error)") }
        }
        lock?.unlock()
        if changed { Sender.kick() }
        return 0
    }
}

enum Commands {
    static func pair(_ args: [String]) -> Int32 {
        // The code may arrive as "123456", "123 456" or "123-456": keep the digits of every argument.
        var typed = ""
        var session: String?
        for a in args {
            if a.hasPrefix("--session=") { session = String(a.dropFirst(10)) }
            else if a.hasPrefix("--code=") { typed += a.dropFirst(7) }
            else if !a.hasPrefix("--") { typed += a }
        }
        let code = String(typed.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
        guard Pairing.isCode(code), typed.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || $0 == " " || $0 == "-" }) else {
            print("Open Sessions on your iPhone, tap Connect, then run /sessions:pair with the six-digit code it shows, for example /sessions:pair 123456.")
            return 0
        }
        let previous = Paired.load()
        guard let base = Env.relayBase(paired: nil) else {
            print("The relay address in SESSIONS_RELAY must start with https://.")
            return 0
        }
        let own = Curve25519.KeyAgreement.PrivateKey()
        let mac = Env.computerName()
        let join: [String: String] = ["code": code, "pub": Pairing.publicKeyBase64(own), "name": Text.clip(mac, 60)]
        let body = (try? JSONSerialization.data(withJSONObject: join)) ?? Data()
        guard let r = HTTP.send("POST", base + "/v1/pair/join", body: body, headers: ["Content-Type": "application/json"], timeout: 10) else {
            print("Could not reach the Sessions relay. Check the internet connection and try again.")
            return 0
        }
        switch r.status {
        case 200: break
        case 404:
            print("That code was not found or has expired, or another computer used it. Make a new code in the Sessions app and try again.")
            return 0
        case 415:
            Log.write("pair: POST /v1/pair/join answered HTTP 415")
            print("The Sessions relay did not take the request (HTTP 415). Update the plugin, then try again.")
            return 0
        case 429:
            print("Too many tries for now. Wait a few minutes, then try again.")
            return 0
        default:
            Log.write("pair: POST /v1/pair/join answered HTTP \(r.status)")
            print("The Sessions relay answered with an error (HTTP \(r.status)). Try again in a moment.")
            return 0
        }
        guard let answer = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any],
              let phonePub = answer["pub"] as? String,
              let k = try? Pairing.deriveK(own: own, otherPublicBase64: phonePub, code: code) else {
            print("The phone's answer could not be read. Make a new code in the Sessions app and try again.")
            return 0
        }
        // The pairing's one-time ticket: this computer's first sealed PUT makes the box with it (64 hex characters).
        let ticket = (answer["ticket"] as? String).flatMap { t in
            t.count == 64 && t.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) ? t : nil
        }

        let oldK = previous.flatMap { KeyStore.load(store: $0.keyStore) }
        let store = Env.keyStore
        if let previous, previous.keyStore != store { KeyStore.delete(store: previous.keyStore) }
        guard KeyStore.save(k, store: store) else {
            print("Could not save the pair key\(store == "keychain" ? " in the Keychain" : ""). Nothing was changed on this computer.")
            return 0
        }
        do {
            try Paired(relay: base, mac: mac, at: Env.now, keyStore: store, ticket: ticket).save()
        } catch {
            print("Could not save the pairing in \(Env.home.path).")
            return 0
        }
        Files.remove(Sent.url)   // a new box: send everything again
        Files.remove(Env.file(Sender.unknownMark))

        // Show the session the command was typed in straight away.
        if let session, !session.isEmpty, !session.hasPrefix("$") {
            let lock = FileLock(StoreFile.lockURL, waitMs: 1000)
            var s = StoreFile.load()
            if s.sessions[session] == nil {
                let now = Env.now
                s.sessions[session] = Rec(id: session, title: Text.folderTitle(FileManager.default.currentDirectoryPath),
                                          titleFrom: "folder", state: "done", reply: nil, needs: nil, since: now,
                                          started: now, last: now, turns: 1, visible: true, finishAlerted: true, stalled: nil)
                try? s.save()
            }
            lock?.unlock()
        }

        // The first sealed state creates the box (with the ticket).
        if !Sender.run() { Log.write("pair: the first state did not reach the relay; the next hook retries") }
        if let oldK, oldK != k {
            _ = HTTP.send("DELETE", (Env.relayBase(paired: previous) ?? base) + "/v1/box", body: nil, headers: Box.headers(oldK), timeout: 3)
        }
        print("Connected to your iPhone.")
        return 0
    }

    static func unpair() -> Int32 {
        let paired = Paired.load()
        let store = paired?.keyStore ?? Env.keyStore
        let k = KeyStore.load(store: store)
        guard paired != nil || k != nil else {
            print("This computer is not connected to a phone.")
            return 0
        }
        // Stop any sender first, so nothing re-creates the box after it is deleted.
        let sendLock = FileLock(Env.file("send.lock"), waitMs: 8000)
        defer { sendLock?.unlock() }
        Files.remove(Paired.url)
        var relayNote = ""
        if let k, let base = Env.relayBase(paired: paired) {
            let r = HTTP.send("DELETE", base + "/v1/box", body: nil, headers: Box.headers(k), timeout: 3)
            // 410: the phone already disconnected and the box is gone.
            if r.map({ (200..<300).contains($0.status) || $0.status == 404 || $0.status == 410 }) != true {
                relayNote = " The relay could not be reached, so its copy will expire on its own."
                Log.write("unpair: DELETE /v1/box failed: \(r.map { "HTTP \($0.status)" } ?? "no answer")")
            }
        }
        Paired.forget(keyStore: store)
        print("Disconnected. This computer no longer sends sessions to your phone.\(relayNote)")
        return 0
    }

    static func status() -> Int32 {
        guard let paired = Paired.load() else {
            print("Not connected to a phone. Run /sessions:pair with the code from the Sessions app.")
            return 0
        }
        let s = StoreFile.load()
        let snap = Picture.snapshot(s, now: Env.now, mac: paired.mac)
        let hasKey = KeyStore.load(store: paired.keyStore) != nil
        print("Connected since \(Date(timeIntervalSince1970: TimeInterval(paired.at)).formatted()) as \"\(paired.mac)\".")
        print("Relay: \(Env.relayBase(paired: paired) ?? "invalid address"). Pair key: \(hasKey ? "in the \(paired.keyStore)" : "missing").")
        if Files.exists(Env.file(Sender.unknownMark)) {
            print("The relay no longer knows this pairing (it deletes one neither device used for 30 days). Make a new code in the Sessions app and run /sessions:pair with it.")
        }
        print("Sessions: \(snap.counts.need) need you, \(snap.counts.working) working, \(snap.counts.finished) finished.")
        print("Log: \(Env.file("log.txt").path)")
        return 0
    }

    static func crypt(_ mode: String) -> Int32 {
        guard let k = Env.vars["OMNIA_KEY"], !k.isEmpty else {
            FileHandle.standardError.write(Data("usage: OMNIA_KEY=... sessions-hook seal|open\n".utf8))
            return 2
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if mode == "seal" {
            guard let sealed = try? Box.seal(input, k: k) else { return 1 }
            FileHandle.standardOutput.write(Data(sealed.utf8))
        } else {
            guard let plain = try? Box.open(String(decoding: input, as: UTF8.self), k: k) else { return 1 }
            FileHandle.standardOutput.write(plain)
        }
        return 0
    }
}

let code: Int32
switch args.first ?? "" {
case "hook": code = Hook.run()
case "send": code = Sender.run() ? 0 : 1
case "pair": code = Commands.pair(Array(args.dropFirst()))
case "unpair": code = Commands.unpair()
case "status": code = Commands.status()
case "seal", "open": code = Commands.crypt(args[0])
case "version", "--version": print(version); code = 0
default:
    FileHandle.standardError.write(Data("usage: sessions-hook hook|pair <code>|unpair|status|version\n".utf8))
    code = 2
}
exit(code)
