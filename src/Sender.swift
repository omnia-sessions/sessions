// Seals the state, leaves it at the relay, and asks the relay for a push when the picture changed.
// Runs detached from the hook, one at a time, every request limited to 3 seconds. A sender that finds another one at
// work does not wait for it: it leaves a mark, and the one at work sends once more when it is done.
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
    /// Seconds between sealed state PUTs while something happens but nothing the phone shows changed. The phone
    /// never reads "asleep" from the age of a plugin's state, and the card goes stale only after 20 minutes.
    static let heartbeat = 300
    static let cardHeartbeat = 300     // seconds between card refreshes while a session works
    /// "Something changed since the last send began": left by a sender that found another at work.
    static let againMark = "send.again"
    /// Left when the relay answered 403 "pair": it does not know this pairing (see `status`).
    static let unknownMark = "relay-unknown"
    /// At most this many sends in a row for marks left meanwhile; a later hook starts the next sender.
    static let maxRounds = 20

    /// Called by a hook after it changed the store.
    static func kick() {
        switch Env.sendMode {
        case "off": return
        case "inline": _ = run()
        default:
            if !Run.detached(["send"]) { Log.write("send: could not start the background sender") }
        }
    }

    /// Sends what changed. When another sender holds the lock, leaves the mark for it and returns at once (true:
    /// handed over). The holder clears the mark before each send and looks for it after unlocking, so a change
    /// made while it sent goes out in one more round, and none is left behind.
    @discardableResult
    static func run() -> Bool {
        guard Paired.load() != nil else { return false }
        let again = Env.file(againMark)
        Files.touch(again)
        var ok = true
        for _ in 0..<maxRounds {
            guard let lock = FileLock(Env.file("send.lock"), waitMs: 0) else { return ok }
            Files.remove(again)
            ok = once()
            lock.unlock()
            if !Files.exists(again) { break }
        }
        return ok
    }

    /// One send, while holding the lock.
    private static func once() -> Bool {
        guard let paired = Paired.load() else { return false }   // unpaired meanwhile
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
                // Until the box exists at the relay, the pairing's ticket goes along: only it lets the first PUT make it.
                if let ticket = paired.ticket { headers["x-ticket"] = ticket }
                let r = HTTP.send("PUT", base + "/v1/state", body: Data(sealed.utf8), headers: headers, timeout: timeout)
                if r?.status == 410 { return phoneDisconnected(paired, "PUT /v1/state") }
                if let r, r.status == 200 {
                    sent.stateFP = stateFP
                    sent.putAt = now
                    if paired.ticket != nil {
                        var done = paired
                        done.ticket = nil
                        try? done.save()
                    }
                    Files.remove(Env.file(unknownMark))
                } else if r?.status == 403 {
                    // The relay keeps no box for this pairing and the ticket cannot make one: neither device used it
                    // for 30 days (the relay deleted it), or the ticket ran out before the first PUT. The key stays;
                    // a new pairing is needed. Logged once.
                    ok = false
                    reachable = false
                    if !Files.exists(Env.file(unknownMark)) {
                        Files.touch(Env.file(unknownMark))
                        Log.write("send: PUT /v1/state answered 403: the relay does not know this pairing any more; run /sessions:pair with a new code")
                    }
                } else {
                    ok = false
                    reachable = r != nil && r?.status != 503
                    Log.write("send: PUT /v1/state failed: \(r.map { "HTTP \($0.status)" } ?? "no answer in \(Int(timeout)) s")")
                }
            } else {
                ok = false
                Log.write("send: sealing failed")
            }
        }

        // The card starts when a session starts working and ends when none is working or waiting.
        let card = Picture.card(snap, titles: Picture.cardTitles(store))
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
