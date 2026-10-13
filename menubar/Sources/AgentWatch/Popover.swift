import SwiftUI

struct Popover: View {
    @EnvironmentObject var store: Store
    @State private var showDone = false
    @State private var contentHeight: CGFloat = 300
    var maxScroll: CGFloat = 560

    var body: some View {
        let s = store.snap
        VStack(spacing: 0) {
            Header(snap: s)
            Divider().opacity(0.6)
            if store.root == nil || !s.configured {
                Unconfigured(root: store.root)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MachineStrip(machine: s.machine)
                        let asks = s.asks
                        if !asks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader(title: "Needs you", count: asks.count, color: Palette.needs)
                                ForEach(asks) { AskCard(ask: $0) }
                            }
                        } else {
                            AllClear()
                        }
                        if !s.working.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionHeader(title: "Working", count: s.working.count)
                                ForEach(s.working) { AgentRow(card: $0) }
                            }
                        }
                        TeammatesSection()
                        if !s.finished.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                                    HStack(spacing: 6) {
                                        SectionHeader(title: "Done", count: s.finished.count, color: .secondary, fill: false)
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                            .rotationEffect(.degrees(showDone ? 90 : 0))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if showDone { ForEach(s.finished) { AgentRow(card: $0) } }
                            }
                        }
                        if !s.events.isEmpty { Activity(events: s.events, cards: s.cards) }
                    }
                    .padding(14)
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                }
                .frame(height: min(contentHeight, maxScroll))
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            }
            Divider().opacity(0.6)
            Footer(updated: s.updated)
        }
        .frame(width: 400)
        .background(Palette.window)          // opaque: readable over any window behind the popover
        .overlay(alignment: .bottom) { ToastView() }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct Header: View {
    let snap: Snapshot
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 11) {
            Ring(value: snap.overall, color: snap.asks.isEmpty ? Palette.work : Palette.needs)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Watch").font(.system(size: 14, weight: .bold))
                Text(snap.configured ? summary : "Not connected").font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if snap.configured { CallMenu(snap: snap) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var summary: String {
        var parts: [String] = []
        let asks = snap.asks.count, working = snap.working.count
        if asks > 0 { parts.append("\(asks) need\(asks == 1 ? "s" : "") you") }
        parts.append("\(working) working")
        if asks == 0 && !snap.finished.isEmpty { parts.append("\(snap.finished.count) done") }
        return parts.joined(separator: " · ")
    }
}

/// Whether the watcher may phone right now, and controls to pause or resume calls.
private struct CallMenu: View {
    let snap: Snapshot
    @EnvironmentObject var store: Store

    var body: some View {
        Menu {
            Section("Pause calls") {
                Button("30 minutes") { store.pause(minutes: 30) }
                Button("1 hour") { store.pause(minutes: 60) }
                Button("2 hours") { store.pause(minutes: 120) }
                Button("4 hours") { store.pause(minutes: 240) }
                Button("Until tomorrow morning") { store.pause(minutes: minutesUntilMorning()) }
            }
            if snap.pausedUntil != nil {
                Divider()
                Button("Resume calls now") { store.pause(minutes: 0) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(text).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.13)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(snap.call.quietHours.map { "Quiet hours \($0)" } ?? "Phone calls")
    }

    private var paused: Date? { snap.pausedUntil }
    private var icon: String { paused == nil ? "phone.fill" : (snap.call.reason == "hours" ? "moon.fill" : "pause.fill") }
    private var color: Color { paused == nil ? Palette.done : .secondary }
    private var text: String {
        guard let p = paused else { return "Calls on" }
        return (snap.call.reason == "hours" ? "Quiet until " : "Paused until ") + Fmt.clock(p)
    }
    private func minutesUntilMorning() -> Int {
        let cal = Calendar.current
        var next = cal.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        if next <= Date() { next = cal.date(byAdding: .day, value: 1, to: next)! }
        return Int(next.timeIntervalSinceNow / 60)
    }
}

private struct MachineStrip: View {
    let machine: Machine

    var body: some View {
        let disk = machine.disk_free_gb ?? -1
        let mem = machine.mem_free_pct ?? -1
        let cpus = Double(machine.cpus ?? 1)
        let load = machine.load?.first ?? 0
        HStack(spacing: 14) {
            Meter(icon: "internaldrive.fill", label: "Disk", value: disk >= 0 ? "\(disk) GB free" : "–",
                  fraction: disk >= 0 ? 1 - min(1, Double(disk) / 400) : 0,
                  color: disk < 0 ? .secondary : disk < 100 ? Palette.needs : disk < 150 ? Palette.warn : Palette.done)
            Meter(icon: "memorychip.fill", label: "Memory", value: mem >= 0 ? "\(mem)% free" : "–",
                  fraction: mem >= 0 ? 1 - Double(mem) / 100 : 0,
                  color: mem < 0 ? .secondary : mem < 15 ? Palette.needs : mem < 30 ? Palette.warn : Palette.done)
            Meter(icon: "cpu.fill", label: "Load", value: String(format: "%.0f / %.0f", load, cpus),
                  fraction: load / max(1, cpus * 2),
                  color: load > cpus * 2 ? Palette.needs : load > cpus ? Palette.warn : Palette.done)
            Meter(icon: "shippingbox.fill", label: "Containers", value: machine.running_containers.map(String.init) ?? "–",
                  fraction: Double(machine.running_containers ?? 0) / 100, color: Palette.work)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
    }
}

private struct AllClear: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(Palette.done)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing needs you").font(.system(size: 12.5, weight: .semibold))
                Text("I'll ping you when an agent does.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
    }
}

private struct Activity: View {
    let events: [Event]
    let cards: [Card]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Recent")
            ForEach(events) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(e.kind)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color(e.kind))
                        .frame(width: 14)
                    Text(describe(e)).font(.system(size: 11.5)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.when(e.date)).font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(_ k: String) -> String {
        ["CALLING": "phone.arrow.up.right.fill", "DELIVERED": "arrowshape.turn.up.right.fill", "NO-ANSWER": "phone.down.fill",
         "SKIPPED": "forward.fill", "RESOURCES": "internaldrive.fill", "RESUMED": "play.fill", "ERROR": "exclamationmark.triangle.fill",
         "RELAY": "arrowshape.turn.up.right.fill", "SENT": "paperplane.fill", "DONE": "checkmark.circle.fill"][k] ?? "circle.fill"
    }
    private func color(_ k: String) -> Color {
        switch k {
        case "ERROR", "NO-ANSWER": return Palette.needs
        case "CALLING", "DELIVERED": return Palette.work
        case "RESUMED", "DONE": return Palette.done
        case "SENT": return Palette.work
        default: return .secondary
        }
    }
    /// Turns watcher log lines into short sentences, naming agents by their short titles.
    private func describe(_ e: Event) -> String {
        let name = { (id: String) in cards.first { $0.name == id || ($0.paseoId ?? "").hasPrefix(id) }?.label ?? id }
        let first = e.text.split(separator: " ").first.map(String.init) ?? ""
        switch e.kind {
        case "RESOURCES": return e.text.prefix(1).uppercased() + e.text.dropFirst()
        case "DONE": return "\(name(e.agent ?? "")): \(e.text)"
        case "SENT":
            let bits = (e.agent ?? "").split(separator: "|").map(String.init)
            return "\(bits.last == "you" ? "You" : "Coordinator") → \(name(bits.first ?? "")): \(e.text)"
        case "RESUMED": return "Restarted \(name(first)) after a usage limit"
        case "CALLING":
            let ids = e.text.components(separatedBy: "about: ").last?.split(separator: ";").map { String($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") } ?? []
            return "Called you about " + ids.map(name).joined(separator: ", ")
        case "SKIPPED": return "You skipped \(name(first)) on a call"
        case "DELIVERED": return "Passed your answer to \(name(first))"
        case "NO-ANSWER": return "No answer about \(name(e.text.components(separatedBy: "for ").dropFirst().first?.split(separator: " ").first.map(String.init) ?? ""))"
        default: return e.text
        }
    }
}

private struct Unconfigured: View {
    let root: URL?
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("claude-watcher isn't running").font(.system(size: 13, weight: .semibold))
            Text(root == nil ? "Start dashboard/run.sh in your claude-watcher checkout." : "No dashboard/state.json in \(root!.path) yet.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

private struct Footer: View {
    let updated: Date?
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 15)) { ctx in
                let stale = updated.map { ctx.date.timeIntervalSince($0) > 600 } ?? true
                HStack(spacing: 4) {
                    Circle().fill(stale ? Palette.warn : Palette.done).frame(width: 5, height: 5)
                    Text("Updated \(Fmt.ago(updated, now: ctx.date))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .help(stale ? "The dashboard loop may have stopped" : "Summaries refresh every few minutes")
            }
            Spacer()
            FooterButton(title: "Dashboard", icon: "square.grid.2x2") { store.openDashboard() }
            FooterButton(title: "Paseo", icon: "arrow.up.forward.app") { store.openPaseo() }
            FooterButton(title: "Quit", icon: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).labelStyle(.titleAndIcon)
                .foregroundStyle(hover ? .primary : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Palette.cardFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ToastView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if let t = store.toast {
            HStack(spacing: 6) {
                Image(systemName: t.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(t.ok ? Palette.done : Palette.needs)
                Text(t.text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 46)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: t.id) {
                try? await Task.sleep(for: .seconds(t.ok ? 2.6 : 6))   // errors stay long enough to read
                // a newer toast cancels this task; it must not clear the newer one
                if !Task.isCancelled, store.toast?.id == t.id { withAnimation { store.toast = nil } }
            }
        }
    }
}
