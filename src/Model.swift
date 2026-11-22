// The local store of sessions, how each hook event changes it, and what goes to the relay.
// States are the app's: need (waiting for you), work (Claude is working), done (finished, idle).
import CryptoKit
import Foundation

struct Rec: Codable, Equatable {
    var id: String
    var title: String
    var titleFrom: String          // folder | prompt | custom
    var state: String              // need | work | done
    var reply: String?             // Claude's last reply, at most 2,000 characters, line breaks kept
    var needs: String?
    var since: Int                 // when the current state began
    var started: Int
    var last: Int                  // last activity seen
    var turns: Int
    var visible: Bool              // shown once it has had a prompt, or was resumed
    var finishAlerted: Bool?
    var stalled: Bool?
    /// The folder's name, the only title the Lock Screen card uses (it passes the relay and Apple readable). The
    /// title above may be the start of a prompt; that one is only ever sealed. Nil in stores from before it.
    var folder: String? = nil
}

struct StoreFile: Codable, Equatable {
    var sessions: [String: Rec] = [:]
    /// Bumped when an alert is due; the sender remembers which it has sent.
    var alertNeed = 0
    var alertDone = 0

    static var url: URL { Env.file("sessions.json") }
    static var lockURL: URL { Env.file("store.lock") }

    static func load() -> StoreFile {
        guard let data = Files.read(url), let s = try? JSONDecoder().decode(StoreFile.self, from: data) else { return StoreFile() }
        return s
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Files.write(try enc.encode(self), to: StoreFile.url)
    }
}

enum Text {
    /// One line, single spaces, at most `limit` characters (an ellipsis marks a cut).
    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Paragraphs kept, trimmed, at most `limit` characters (an ellipsis marks a cut). For the reply in full.
    static func cut(_ text: String, _ limit: Int) -> String {
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    static func folderTitle(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Session" }
        if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "Home" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Session" : clip(name, 60)
    }

    /// The first real line of a prompt, without pasted blocks. Nil for slash commands and tags.
    static func promptTitle(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        var inPaste = false
        for raw in prompt.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("<pasted_content") { inPaste = true; continue }
            if line.hasPrefix("</pasted_content") { inPaste = false; continue }
            if inPaste || line.isEmpty { continue }
            if line.hasPrefix("/") || line.hasPrefix("<") { return nil }
            return clip(line, 60)
        }
        return nil
    }
}

enum Events {
    static let maxAgeDone = 24 * 3600
    static let maxAge = 48 * 3600
    static let stallAfter = 30 * 60

    /// Applies one hook event (the JSON Claude Code passes on stdin). Returns whether the store changed.
    static func apply(_ input: [String: Any], to store: inout StoreFile, now: Int) -> Bool {
        var changed = tidy(&store, now: now)
        guard let sid = input["session_id"] as? String, !sid.isEmpty else { return changed }
        let event = input["hook_event_name"] as? String ?? ""
        let cwd = input["cwd"] as? String
        let custom = (input["session_title"] as? String).map { Text.clip($0, 80) }.flatMap { $0.isEmpty ? nil : $0 }

        func fresh() -> Rec {
            Rec(id: sid, title: Text.folderTitle(cwd), titleFrom: "folder", state: "done", reply: nil, needs: nil,
                since: now, started: now, last: now, turns: 0, visible: false, finishAlerted: nil, stalled: nil,
                folder: Text.folderTitle(cwd))
        }

        let before = store.sessions[sid]
        var r = before ?? fresh()

        switch event {
        case "SessionStart":
            let source = input["source"] as? String ?? "startup"
            if before == nil {
                r.visible = source == "resume" || source == "fork"
            } else if source != "compact" {
                // Resumed or restarted: idle until the next prompt.
                if r.state != "done" { r.state = "done"; r.since = now }
                r.needs = nil
                r.stalled = nil
                r.last = now
            }
            if r.titleFrom == "folder", cwd != nil { r.title = Text.folderTitle(cwd) }

        case "UserPromptSubmit":
            r.turns += 1
            r.state = "work"
            r.since = now
            r.last = now
            r.needs = nil
            r.visible = true
            r.finishAlerted = nil
            r.stalled = nil
            if r.titleFrom == "folder", let t = Text.promptTitle(input["prompt"] as? String) {
                r.title = t
                r.titleFrom = "prompt"
            }

        case "Notification":
            let type = input["notification_type"] as? String ?? ""
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                if r.state != "need" {
                    r.state = "need"
                    r.since = now
                    store.alertNeed += 1
                }
                let message = Text.clip(input["message"] as? String ?? "", 200)
                r.needs = !message.isEmpty ? message
                    : type == "permission_prompt" ? "Waiting for your permission" : "Waiting for your answer"
                r.last = now
                r.visible = true
            case "idle_prompt":
                // Claude finished about a minute ago and nobody typed since.
                if r.state == "work" {
                    // Stop does not fire after an interrupt; the person was at the computer, so no alert.
                    r.state = "done"
                    r.since = now
                    r.finishAlerted = true
                } else if r.state == "done", r.turns > 0, r.finishAlerted != true, before != nil {
                    store.alertDone += 1
                    r.finishAlerted = true
                } else {
                    return changed
                }
            default:
                return changed
            }

        case "PostToolUse":
            // Only to notice that Claude carries on after a permission prompt, plus a slow heartbeat while working.
            guard before != nil else { return changed }
            if r.state == "need" || r.stalled == true {
                r.state = "work"
                r.since = now
                r.needs = nil
                r.stalled = nil
                r.last = now
            } else if r.state == "work", now - r.last >= 60 {
                r.last = now
            } else {
                return changed
            }

        case "Stop":
            r.state = "done"
            r.since = now
            r.last = now
            r.needs = nil
            r.stalled = nil
            r.visible = true
            if r.turns == 0 { r.turns = 1 }
            let reply = Text.cut(input["last_assistant_message"] as? String ?? "", Picture.maxReply)
            if !reply.isEmpty { r.reply = reply }

        case "StopFailure":
            if r.state != "need" { store.alertNeed += 1 }
            r.state = "need"
            r.since = now
            r.last = now
            r.stalled = nil
            r.visible = true
            let error = input["error"] as? String ?? ""
            r.needs = error.isEmpty ? "Stopped by an error" : "Stopped by an error (\(Text.clip(error, 40)))"

        case "SessionEnd":
            return store.sessions.removeValue(forKey: sid) != nil || changed

        default:
            return changed
        }

        if let custom { r.title = custom; r.titleFrom = "custom" }
        if let cwd, !cwd.isEmpty { r.folder = Text.folderTitle(cwd) }
        if before != r {
            store.sessions[sid] = r
            changed = true
        }
        return changed
    }

    /// Forgets old sessions (Claude Code may have quit without SessionEnd) and stops showing
    /// a session as working when nothing has happened in it for half an hour.
    static func tidy(_ store: inout StoreFile, now: Int) -> Bool {
        var changed = false
        for (id, r) in store.sessions {
            let age = now - r.last
            if age > maxAge || (r.state == "done" && age > maxAgeDone) {
                store.sessions.removeValue(forKey: id)
                changed = true
            } else if r.state == "work", age > stallAfter {
                var s = r
                s.state = "done"
                s.since = now
                s.stalled = true
                s.finishAlerted = true
                store.sessions[id] = s
                changed = true
            }
        }
        return changed
    }
}

// MARK: - What the phone decodes (app/Shared/Models.swift: Snapshot, Snapshot.Session, Relay.State)

struct SnapSession: Codable, Equatable {
    var id: String
    var title: String
    var state: String
    var note: String?              // the last reply as one short line (300 characters)
    var needs: String?
    var since: Int
    var started: Int?
    var last: Int?
    var turns: Int?
    var reply: String?             // the last reply in full (2,000 characters): "Latest reply" on the phone. Sealed only,
                                   // never in a push.
}

struct Counts: Codable, Equatable {
    var need: Int
    var working: Int
    var finished: Int
}

struct Snap: Codable, Equatable {
    var updated: Int
    var mac: String
    var counts: Counts
    var sessions: [SnapSession]
}

struct RelayState: Codable {
    var snapshot: Snap
    var jobs: [String]
    var promptsOn: Bool
}

/// SessionsAttributes.ContentState: counts and short titles only, never reply text.
struct CardState: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var title: String
        var note: String
        var state: String
        var since: Int
    }
    var need: Int
    var working: Int
    var finished: Int
    var updated: Int
    var macAwake: Bool
    var items: [Item]
}

struct NotifyBody: Encodable {
    struct Alert: Encodable { var title: String; var body: String }
    var event: String
    var contentState: CardState
    var alert: Alert?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(event, forKey: .event)
        try c.encode(contentState, forKey: .contentState)
        if let alert { try c.encode(alert, forKey: .alert) } else { try c.encodeNil(forKey: .alert) }
    }

    enum CodingKeys: String, CodingKey { case event, contentState, alert }
}

enum Picture {
    static let maxSessions = 30
    static let maxCardItems = 5
    static let maxNote = 300
    static let maxReply = 2000
    /// Replies together stay under this many bytes, so the sealed state stays well inside the relay's 256 KB.
    /// Sessions are in the order the phone shows them; one past the budget keeps its note and goes without the reply.
    static let maxReplyBytes = 120_000
    static let order = ["need": 0, "work": 1, "done": 2]

    static func snapshot(_ store: StoreFile, now: Int, mac: String) -> Snap {
        let shown = store.sessions.values.filter { $0.visible }.sorted {
            (order[$0.state] ?? 3, -$0.last, $0.id) < (order[$1.state] ?? 3, -$1.last, $1.id)
        }
        var counts = Counts(need: 0, working: 0, finished: 0)
        for r in shown {
            switch r.state {
            case "need": counts.need += 1
            case "work": counts.working += 1
            default: counts.finished += 1
            }
        }
        var replyBytes = 0
        let sessions = shown.prefix(maxSessions).map { r in
            // While Claude works, the stored reply belongs to the previous turn: not shown as the session's note.
            // It is still its latest reply, so it stays under "Latest reply".
            let note = r.state == "work" ? nil : r.reply.map { Text.clip($0, maxNote) }
            var reply = r.reply.map { Text.cut($0, maxReply) }
            if let full = reply {
                if replyBytes + full.utf8.count > maxReplyBytes { reply = nil } else { replyBytes += full.utf8.count }
            }
            return SnapSession(id: r.id, title: Text.clip(r.title, 80), state: r.state,
                               note: note, needs: r.state == "need" ? r.needs : nil,
                               since: r.since, started: r.started, last: r.last, turns: r.turns, reply: reply)
        }
        return Snap(updated: now, mac: Text.clip(mac, 60), counts: counts, sessions: Array(sessions))
    }

    /// The card's title for each session: its folder's name, never the start of a prompt or a custom title.
    static func cardTitles(_ store: StoreFile) -> [String: String] {
        store.sessions.mapValues { $0.folder ?? ($0.titleFrom == "folder" ? $0.title : "Session") }
    }

    /// The Lock Screen card. Its titles are `titles` (folder names, `cardTitles`), so no prompt text is ever in it.
    static func card(_ snap: Snap, titles: [String: String]) -> CardState {
        let items = snap.sessions.filter { $0.state != "done" }.prefix(maxCardItems).map {
            CardState.Item(id: $0.id, title: Text.clip(titles[$0.id] ?? "Session", 40), note: "", state: $0.state, since: $0.since)
        }
        return CardState(need: snap.counts.need, working: snap.counts.working, finished: snap.counts.finished,
                         updated: snap.updated, macAwake: true, items: Array(items))
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(value)) ?? Data("{}".utf8)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Changes when anything the phone shows changes, not with the clock: not with `updated`, and not with a
    /// session's `last`, which PostToolUse moves every minute of work and the phone does not show. (A change in the
    /// order it gives the sessions still counts.) The heartbeat in Sender carries the new times along.
    static func stateFingerprint(_ snap: Snap) -> String {
        var s = snap
        s.updated = 0
        s.sessions = s.sessions.map { var x = $0; x.last = nil; return x }
        return digest(encode(s))
    }

    /// The need/working picture: which sessions need you or are working, and their card titles.
    static func cardFingerprint(_ card: CardState) -> String {
        var c = card
        c.updated = 0
        c.finished = 0
        c.items = c.items.map { var i = $0; i.since = 0; return i }
        return digest(encode(c))
    }
}
