import SwiftUI

private let kindLabel = ["question": "QUESTION", "permission": "PERMISSION", "waiting": "WAITING ON YOU",
                         "stalled": "STALLED", "finished": "FINISHED", "closed": "STOPPED"]

/// Something waiting on the user: what it needs, quick answers, a reply box, and call / later / open.
struct AskCard: View {
    let ask: Ask
    @EnvironmentObject var store: Store
    @State private var reply = ""
    @State private var expanded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 7) {
                PulsingDot(color: Palette.needs, active: !ask.held)
                Text(ask.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Chip(text: kindLabel[ask.kind] ?? "NEEDS YOU", color: Palette.needs, filled: true)
            }

            Text(ask.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }

            if let card = ask.card, card.countable != nil || card.percent > 0 {
                ProgressBar(card: card, color: Palette.needs.opacity(0.75), height: 4)
            }

            if !ask.options.isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(ask.options, id: \.self) { o in
                        SoftButton(title: o, tint: Palette.needs, busy: store.busy.contains(ask.id)) { store.say(ask.id, o) }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Reply to \(ask.name)…", text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.field))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(focused ? Palette.needs : Palette.hairline))
                    .onSubmit(send)
                    // Return sends, Shift-Return adds a line; handled before the field so a popover can't swallow it
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        send(); return .handled
                    }
                Button(action: send) {
                    Image(systemName: store.busy.contains(ask.id) ? "ellipsis" : "arrow.up")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(reply.isEmpty ? Color.secondary.opacity(0.35) : Palette.needs))
                }
                .buttonStyle(.plain)
                .disabled(reply.isEmpty || store.busy.contains(ask.id))
                .help("Send to the agent as you")
                .accessibilityLabel("Send reply")
            }

            HStack(spacing: 6) {
                SoftButton(title: "Open", icon: "arrow.up.forward.app") { store.open(ask.card) }
                SoftButton(title: "Call me", icon: "phone.fill", tint: Palette.needs, busy: store.busy.contains(ask.id)) { store.callNow(ask.id) }
                if !ask.held {
                    SoftButton(title: "Later", icon: "clock") { store.hold(ask.id) }
                        .help("Keep it on your list without phoning about it")
                }
                Spacer()
                if let at = ask.callAt {
                    TimelineView(.periodic(from: .now, by: 5)) { ctx in
                        Label(Fmt.countdown(to: at, now: ctx.date), systemImage: "phone.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.needs)
                    }
                } else if ask.held {
                    Label("On hold for now", systemImage: "phone.down.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .help("Held: no calls about it for a few hours (HOLD_HOURS), or until you reply")
                }
            }
        }
        .padding(11)
        .padding(.leading, 3)
        // a solid card with a red edge: colour as a strong signal, not a faint tint behind the text
        .background(Palette.cardFill)
        .overlay(alignment: .leading) { Palette.needs.frame(width: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.needs.opacity(0.45), lineWidth: 1))
    }

    private func send() {
        guard !reply.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.say(ask.id, reply)
        reply = ""
    }
}

/// A working (or finished) agent: compact row that expands into what it has done, plus open and message.
struct AgentRow: View {
    let card: Card
    @EnvironmentObject var store: Store
    @State private var expanded = false
    @State private var hover = false
    @State private var message = ""

    var body: some View {
        let color = Palette.color(for: card)
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        PulsingDot(color: color, active: card.running)
                        Text(card.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(progressText).font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(card.running ? "working" : card.replied == true ? "you replied" : card.idleMinutes < 2 ? "active" : "idle \(Fmt.idle(card.idleMinutes))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(card.running ? color : (card.idleMinutes > 30 && card.state == "work" ? Palette.warn : .secondary))
                            .frame(minWidth: 44, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    ProgressBar(card: card, color: color)
                    if let doing = card.doing, !doing.isEmpty {
                        Text(doing).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 1).fixedSize(horizontal: false, vertical: expanded)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(card.doneItems.prefix(5), id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Palette.done)
                            Text(item).font(.system(size: 11.5)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
                HStack(spacing: 6) {
                    TextField("Message \(card.name)…", text: $message)
                        .textFieldStyle(.plain).font(.system(size: 11.5))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.field))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline))
                        .onSubmit(sendMessage)
                        .onKeyPress(.return, phases: .down) { _ in sendMessage(); return .handled }
                    SoftButton(title: "Open", icon: "arrow.up.forward.app") { store.open(card) }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(hover || expanded ? Palette.work.opacity(0.5) : Palette.hairline))
        .onHover { hover = $0 }
    }

    private func sendMessage() {
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.say(card.sid, message)
        message = ""
    }

    private var progressText: String {
        if let p = card.countable { return "\(p.done)/\(p.total)" }
        return "\(card.percent)%"
    }
}

/// Wraps its children onto new lines (quick-answer options).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}
