import Foundation

// The files claude-watcher writes (see dashboard/gen.py, watcher.py, resources.py). Everything is optional so a
// half-written or older file still decodes.

struct Progress: Codable, Hashable {
    var done: Int
    var total: Int
    var unit: String
}

struct Card: Codable, Identifiable, Hashable {
    var sid: String
    var title: String
    var shortTitle: String?
    var status: String?
    var quietMin: Int?
    var name: String
    var paseoId: String?
    var state: String           // you | work | done | closed
    var pct: Int?
    var progress: Progress?
    var done: [String]?
    var doing: String?
    var need: String?
    var waiting: String?        // what the summariser says it's waiting on the user for, even if background work runs
    var summaryAt: Double?      // when that summary was written
    var lastActive: String?
    // live from Paseo (overlaid every few seconds, see Loader.live)
    var replied: Bool? = nil    // someone wrote to it after its summary, so the summary's ask is out of date
    var attention: String? = nil // Paseo says it is blocked on a permission or question right now

    var id: String { sid }
    var label: String { (shortTitle?.isEmpty == false ? shortTitle : nil) ?? title }
    var running: Bool { status == "running" }
    var percent: Int { pct ?? 0 }
    var doneItems: [String] { done ?? [] }
    var idleMinutes: Int { quietMin ?? 0 }
    /// Countable progress ("4 of 8 lanes"); the summariser's "tenths" is a rough estimate, shown as a percentage.
    /// Waiting on the user: marked so, or idle with an open ask (background watchers can keep it out of "you").
    var asksUser: Bool {
        if attention != nil { return true }
        if running || replied == true { return false }
        return state == "you" || waiting?.isEmpty == false
    }
    var countable: Progress? {
        guard let p = progress, p.unit != "tenths", p.total > 1 else { return nil }
        return p
    }
}

struct DashboardState: Codable {
    var updated: Double?
    var overall: Int?
    var cards: [Card]?
}

struct Need: Codable, Identifiable, Hashable {
    var sid: String
    var name: String
    var title: String
    var kind: String            // question | permission | waiting | stalled | finished | closed
    var need: String
    var options: [String]?
    var paseo_id: String?
    var callAt: Double?
    var held: Bool?
    var id: String { sid }
}

struct CallStatus: Codable, Equatable {
    var pausedUntil: Double?
    var reason: String?         // hours | manual
    var quietHours: String?
}

struct Machine: Codable, Equatable {
    var load: [Double]?
    var cpus: Int?
    var mem_free_pct: Int?
    var disk_free_gb: Int?
    var running_containers: Int?
    var time: Double?
}

struct Event: Identifiable, Hashable {
    var id: String
    var date: Date
    var kind: String            // a watcher event (CALLING, RESUMED, ...), SENT, or DONE (an agent's latest milestone)
    var text: String
    var agent: String? = nil    // short agent name, for SENT and DONE
}

/// One thing waiting on the user: an agent the summariser marked "needs you", a call the watcher has queued, or both.
struct Ask: Identifiable, Hashable {
    var card: Card?
    var need: Need?
    var held: Bool
    var id: String { card?.sid ?? need!.sid }
    var name: String { card?.name ?? need!.name }
    var title: String { card?.label ?? need!.title }
    var text: String { need?.need ?? card?.attention ?? card?.need ?? card?.waiting ?? card?.doing ?? "" }
    var kind: String { need?.kind ?? "waiting" }
    var options: [String] { need?.options ?? [] }
    var paseoId: String? { card?.paseoId ?? need?.paseo_id }
    /// When the watcher will phone about it, if a call is queued and not held back.
    var callAt: Date? {
        guard let n = need, let t = n.callAt, n.held != true, !held else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}

struct Snapshot: Equatable {
    var configured = false
    var updated: Date?
    var overall = 0
    var cards: [Card] = []
    var needs: [Need] = []
    var held: Set<String> = []
    var call = CallStatus()
    var machine = Machine()
    var events: [Event] = []

    var asks: [Ask] {
        var out: [Ask] = []
        var seen = Set<String>()
        for n in needs {
            let card = cards.first { $0.sid == n.sid }
            // the watcher's list lags by up to a minute: drop what's live-resolved since
            if let c = card, c.attention == nil, c.running || c.replied == true { continue }
            out.append(Ask(card: card, need: n, held: held.contains(n.sid)))
            seen.insert(n.sid)
        }
        for c in cards where c.asksUser && !seen.contains(c.sid) {
            out.append(Ask(card: c, need: nil, held: held.contains(c.sid)))
        }
        return out
    }
    var working: [Card] {
        let asking = Set(asks.map(\.id))
        return cards.filter { ($0.state == "work" || $0.state == "closed") && !asking.contains($0.sid) }
            .sorted { ($0.running ? 0 : 1, $0.idleMinutes) < ($1.running ? 0 : 1, $1.idleMinutes) }
    }
    var finished: [Card] {
        let asking = Set(asks.map(\.id))
        return cards.filter { $0.state == "done" && !asking.contains($0.sid) }
    }
    /// Calls are paused (quiet hours or a manual pause) until this time.
    var pausedUntil: Date? {
        guard let t = call.pausedUntil, t > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}

enum Loader {
    static let shownEvents: Set<String> = ["CALLING", "DELIVERED", "NO-ANSWER", "SKIPPED", "RESOURCES", "RESUMED", "ERROR", "RELAY"]

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func load(root: URL) -> Snapshot {
        var s = Snapshot()
        guard let state = read(DashboardState.self, root.appendingPathComponent("dashboard/state.json")) else { return s }
        s.configured = true
        s.updated = state.updated.map { Date(timeIntervalSince1970: $0) }
        s.overall = state.overall ?? 0
        // the coordinator itself and anything archived never reach state.json
        s.cards = state.cards ?? []
        s.needs = read([Need].self, root.appendingPathComponent("needs.json")) ?? []
        s.call = read(CallStatus.self, root.appendingPathComponent("call_status.json")) ?? CallStatus()
        s.machine = read(Machine.self, root.appendingPathComponent("resources.json")) ?? Machine()
        let decisions = root.appendingPathComponent("decisions")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: decisions.path)) ?? []
        s.held = Set(files.filter { $0.hasSuffix(".hold") || $0.hasSuffix(".park") }.map { String($0.split(separator: ".")[0]) })
        overlayLive(&s)
        s.events = feed(root.appendingPathComponent("watcher.log"), cards: s.cards)
        return s
    }

    /// Paseo's own per-agent records (~/.paseo/agents/*/*.json) are written the moment anything changes; the
    /// summaries behind state.json are minutes old. Overlay status, idle time, replies and pending approvals.
    static func overlayLive(_ s: inout Snapshot, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let dir = home.appendingPathComponent(".paseo/agents")
        let fm = FileManager.default
        var live: [String: [String: Any]] = [:]
        for sub in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let folder = dir.appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(f)),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? String else { continue }
                live[id] = obj
            }
        }
        guard !live.isEmpty else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        s.cards = s.cards.compactMap { c in
            guard let id = c.paseoId, let a = live[id] else { return c }
            if a["archivedAt"] is String { return nil }
            var c = c
            if let st = a["lastStatus"] as? String { c.status = st }
            if let at = date(a["lastActivityAt"]) { c.quietMin = max(0, Int(Date().timeIntervalSince(at) / 60)) }
            if let u = date(a["lastUserMessageAt"]), let sum = c.summaryAt { c.replied = u.timeIntervalSince1970 > sum + 5 }
            if a["requiresAttention"] as? Bool == true, let why = a["attentionReason"] as? String, why != "finished" {
                c.attention = why == "permission" ? "Waiting for your approval in Paseo." : "Waiting on you in Paseo (\(why))."
            }
            return c
        }
    }

    /// Recent activity, newest first: what agents finished (from their summaries), what you and the coordinator
    /// sent them, and the watcher's calls, restarts and machine upkeep.
    static func feed(_ log: URL, cards: [Card], limit: Int = 8) -> [Event] {
        var out = logEvents(log)
        let dayAgo = Date().addingTimeInterval(-86_400)
        for c in cards {
            guard let at = c.summaryAt, let first = c.doneItems.first else { continue }
            let d = Date(timeIntervalSince1970: at)
            if d > dayAgo { out.append(Event(id: "done-\(c.sid)", date: d, kind: "DONE", text: first, agent: c.name)) }
        }
        // disk cleanups repeat every few minutes: only the latest one is news
        var sawResources = false
        out = out.sorted { $0.date > $1.date }.filter { e in
            guard e.kind == "RESOURCES" else { return true }
            defer { sawResources = true }
            return !sawResources
        }
        return Array(out.prefix(limit))
    }

    /// watcher.log lines are "HH:MM:SS EVENT KIND …" or "HH:MM:SS SENT <agent> <who> <text>", with no date: walk back
    /// from the newest line, stepping back a day whenever the clock jumps forward.
    static func logEvents(_ url: URL) -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        var lastSeconds = Int.max
        var out: [Event] = []
        for (i, line) in text.split(separator: "\n").enumerated().reversed() {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count >= 3 else { continue }
            let hms = parts[0].split(separator: ":").compactMap { Int($0) }
            guard hms.count == 3 else { continue }
            let seconds = hms[0] * 3600 + hms[1] * 60 + hms[2]
            if seconds > lastSeconds { day = cal.date(byAdding: .day, value: -1, to: day)! }
            lastSeconds = seconds
            if day < cal.date(byAdding: .day, value: -2, to: Date())! { break }
            let date = day.addingTimeInterval(TimeInterval(seconds))
            if parts[1] == "EVENT", parts.count == 4 {
                let kind = parts[2], rest = parts[3]
                guard shownEvents.contains(kind) else { continue }
                out.append(Event(id: "l\(i)", date: date, kind: kind, text: rest))
            } else if parts[1] == "SENT", parts.count == 4 {
                // SENT <agent> <who> <text>
                let more = parts[3].split(separator: " ", maxSplits: 1).map(String.init)
                out.append(Event(id: "l\(i)", date: date, kind: "SENT", text: more.count > 1 ? more[1] : "", agent: parts[2]
                                 + (more.first == "you" ? "|you" : "|coordinator")))
            }
            if out.count > 60 { break }
        }
        return out
    }

}
