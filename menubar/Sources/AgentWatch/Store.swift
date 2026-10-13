import AppKit
import Foundation
import UserNotifications

/// Reads claude-watcher's files every few seconds and runs its coord.py for every action, so the menu bar behaves
/// exactly like the phone calls and the Paseo plugin.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var snap = Snapshot()
    @Published var toast: Toast?
    @Published var busy: Set<String> = []

    let root: URL?
    private var timer: Timer?
    private var known: Set<String>? = nil      // asks seen so far; nil until the first load, so launch doesn't notify
    private let notify: Bool

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let ok: Bool
    }

    init(root: URL? = Store.findRoot(), live: Bool = true) {
        self.root = root
        self.notify = live
        reload()
        guard live else { return }
        Task.detached(priority: .utility) { _ = Shell.path }   // look up the login PATH now, not on the first click
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        if Store.canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    /// Notifications need a real app bundle; a bare binary (swift run, tests) would crash asking for them.
    nonisolated static let canNotify = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    /// claude-watcher's dashboard/run.sh records its checkout in ~/.config/claude-watcher/root.
    nonisolated static func findRoot() -> URL? {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_WATCHER_DIR"] { return URL(fileURLWithPath: dir) }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-watcher/root")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func reload() {
        guard let root else { return }
        let next = Loader.load(root: root)
        let ids = Set(next.asks.map(\.id))
        if let known, notify {
            for ask in next.asks where !known.contains(ask.id) { post(ask) }
        }
        known = ids
        if next != snap { snap = next }      // unchanged files shouldn't redraw the window
    }

    private func post(_ ask: Ask) {
        guard Store.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(ask.title) needs you"
        content.body = ask.text
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ask.id, content: content, trigger: nil))
    }

    // MARK: actions (all through coord.py)

    func say(_ sid: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        run(sid, ["say", sid, t], done: "Sent")
    }
    func callNow(_ sid: String) { run(sid, ["callnow", sid], done: "Calling you on the next check") }
    func hold(_ sid: String) { run(sid, ["hold", sid], done: "Kept on your list, no calls") }
    func pause(minutes: Int) { run("quiet", ["quiet", String(minutes)], done: minutes > 0 ? "Calls paused" : "Calls on") }

    func open(_ card: Card?) {
        guard let id = card?.paseoId, let server = Store.paseoServerId(),
              let url = URL(string: "paseo://h/\(server)/agent/\(id)") else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Paseo.app"))
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openPaseo() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Paseo.app")) }

    /// The HTML dashboard: DASHBOARD_OUT from claude-watcher's .env if set, else dashboard/index.html.
    func openDashboard() {
        var candidates: [URL] = []
        if let root, let env = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8),
           let line = env.split(separator: "\n").first(where: { $0.hasPrefix("DASHBOARD_OUT=") }) {
            let value = line.dropFirst("DASHBOARD_OUT=".count).split(separator: "#")[0].trimmingCharacters(in: .whitespaces)
            candidates.append(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
        }
        if let root { candidates.append(root.appendingPathComponent("dashboard/index.html")) }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { NSWorkspace.shared.open(url) }
    }

    /// Paseo deep links name the daemon's server id, which it records in ~/.paseo/paseo.pid.
    nonisolated static func paseoServerId() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".paseo/paseo.pid")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["serverId"] as? String
    }

    private func run(_ key: String, _ args: [String], done: String) {
        guard let root else { return }
        busy.insert(key)
        Task.detached {
            let result = Shell.coord(root: root, args)
            await MainActor.run {
                self.busy.remove(key)
                self.toast = Toast(text: result.ok ? done : result.message, ok: result.ok)
                self.reload()
            }
        }
    }
}

enum Shell {
    /// A GUI app starts with a bare PATH; coord.py needs python3, paseo and node, so borrow the login shell's.
    static let path: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        do { try p.run() } catch { return fallback }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return fallback }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.contains("/bin") ? s : fallback
    }()

    static func coord(root: URL, _ args: [String]) -> (ok: Bool, message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "coord.py"] + args
        p.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, error.localizedDescription) }
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let msg = (p.terminationStatus == 0 ? o : (e.isEmpty ? o : e)).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, String(msg.suffix(200)))
    }
}
