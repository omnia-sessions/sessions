// Seals the state, leaves it at the relay, and asks the relay for a push when the picture changed.
// Runs detached from the hook, one at a time, every request limited to 3 seconds.
import Foundation

/// What the sender last delivered, so it only sends what changed.
struct Sent: Codable {
    var stateFP = ""
    var putAt = 0
    var cardFP = ""
    var cardOn = false
    var notifyAt = 0
    var alertNeed = 0
    var alertDone = 0

    static var url: URL { Env.file("sent.json") }
    static func load() -> Sent {
        guard let data = Files.read(url), let s = try? JSONDecoder().decode(Sent.self, from: data) else { return Sent() }
        return s
    }
    func save() { try? Files.write(Picture.encode(self), to: Sent.url) }
}

enum Sender {
    static let timeout: TimeInterval = 3
    static let heartbeat = 55          // seconds between sealed state PUTs while something happens
    static let cardHeartbeat = 300     // seconds between card refreshes while a session works

    /// Called by a hook after it changed the store.
    static func kick() {
        switch Env.sendMode {
        case "off": return
        case "inline": _ = run()
        default:
            if !Run.detached(["send"]) { Log.write("send: could not start the background sender") }
        }
    }

    @discardableResult
    static func run() -> Bool {
        guard Paired.load() != nil else { return false }
        guard let lock = FileLock(Env.file("send.lock"), waitMs: 8000) else {
            Log.write("send: another sender held the lock too long; skipped")
            return false
        }
        defer { lock.unlock() }
        guard let paired = Paired.load() else { return false }   // unpaired while waiting
        guard let k = KeyStore.load(store: paired.keyStore) else {
            Log.write("send: no pair key found (\(paired.keyStore)); run /sessions:pair again")
            return false
        }
        guard let base = Env.relayBase(paired: paired) else {
            Log.write("send: relay address is not https")
            return false
        }
        let storeLock = FileLock(StoreFile.lockURL, waitMs: 1000)
        let store = StoreFile.load()
        storeLock?.unlock()
        let now = Env.now
        let snap = Picture.snapshot(store, now: now, mac: paired.mac)
        var sent = Sent.load()
        var ok = true
        var reachable = true

        let stateFP = Picture.stateFingerprint(snap)
        if stateFP != sent.stateFP || now - sent.putAt >= heartbeat {
            let plain = Picture.encode(RelayState(snapshot: snap, jobs: [], promptsOn: false))
            if let sealed = try? Box.seal(plain, k: k) {
                var headers = Box.headers(k)
                headers["Content-Type"] = "text/plain"
                let r = HTTP.send("PUT", base + "/v1/state", body: Data(sealed.utf8), headers: headers, timeout: timeout)
                if r?.status == 410 { return phoneDisconnected(paired, "PUT /v1/state") }
                if let r, r.status == 200 {
                    sent.stateFP = stateFP
                    sent.putAt = now
                } else {
                    ok = false
                    reachable = r != nil
                    Log.write("send: PUT /v1/state failed: \(r.map { "HTTP \($0.status)" } ?? "no answer in \(Int(timeout)) s")")
                }
            } else {
                ok = false
                Log.write("send: sealing failed")
            }
        }

        // The card starts when a session starts working and ends when none is working or waiting.
        let card = Picture.card(snap)
        let active = card.need + card.working > 0
        let cardFP = Picture.cardFingerprint(card)
        var event: String?
        if !sent.cardOn && active {
            event = "start"
        } else if sent.cardOn && !active {
            event = "end"
        } else if sent.cardOn && cardFP != sent.cardFP {
            event = "update"
        } else if sent.cardOn && active && now - sent.notifyAt >= cardHeartbeat {
            // The card goes stale after 20 minutes without an update; PostToolUse wakes the sender
            // about once a minute during work, and this refreshes the card at most every 5 minutes.
            event = "update"
        }
        var alert: String?
        if store.alertNeed > sent.alertNeed {
            alert = "A session needs you"
        } else if store.alertDone > sent.alertDone {
            alert = "A session finished"
        }
        if event == nil, alert != nil { event = active ? "update" : "end" }

        // A relay that did not answer the state will not answer the push either; the next hook retries both.
        if let event, reachable {
            let body = NotifyBody(event: event, contentState: card,
                                  alert: alert.map { NotifyBody.Alert(title: "Sessions", body: $0) })
            var headers = Box.headers(k)
            headers["Content-Type"] = "application/json"
            let r = HTTP.send("POST", base + "/v1/push/notify", body: Picture.encode(body), headers: headers, timeout: timeout)
            if r?.status == 410 { return phoneDisconnected(paired, "POST /v1/push/notify") }
            if let r, (200..<300).contains(r.status) {
                sent.cardFP = cardFP
                sent.cardOn = event != "end"
                sent.notifyAt = now
                sent.alertNeed = store.alertNeed
                sent.alertDone = store.alertDone
            } else {
                ok = false
                Log.write("send: POST /v1/push/notify (\(event)) failed: \(r.map { "HTTP \($0.status)" } ?? "no answer in \(Int(timeout)) s")")
            }
        }
        sent.save()
        return ok
    }

    /// The relay answers 410 for a box the phone deleted ("Disconnect"). Then this computer unpairs itself, so it
    /// stops sending and nothing tries to bring the box back. Returns false: nothing was delivered.
    private static func phoneDisconnected(_ paired: Paired, _ request: String) -> Bool {
        Paired.forget(keyStore: paired.keyStore)
        Log.write("send: \(request) answered 410: the phone disconnected, so this computer unpaired itself (pair key and pairing removed)")
        return false
    }
}
