import SwiftUI

enum Palette {
    static let needs = Color(nsColor: .systemRed)
    static let work = Color(nsColor: .systemBlue)
    static let done = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    // Content sits on solid surfaces, not glass (Apple HIG: no Liquid Glass in the content layer), so text stays
    // readable whatever is behind the popover. System colours adapt to dark mode and Increase Contrast.
    static let window = Color(nsColor: .windowBackgroundColor)       // the popover's backdrop
    static let cardFill = Color(nsColor: .controlBackgroundColor)    // cards on it
    static let raised = Color(nsColor: .windowBackgroundColor)       // insets inside a card
    static let field = Color(nsColor: .textBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let track = Color(nsColor: .quaternaryLabelColor)
    static let card = cardFill

    static func color(for card: Card, asking: Bool = false) -> Color {
        if asking || card.state == "you" { return needs }
        switch card.state {
        case "done": return done
        case "closed": return warn
        default: return work
        }
    }
}

/// One segment per unit when progress is countable (3 of 8 steps = 8 segments); a smooth bar otherwise.
struct ProgressBar: View {
    let card: Card
    var color: Color
    var height: CGFloat = 5

    var body: some View {
        if let p = card.countable, p.total <= 30 {
            HStack(spacing: p.total > 16 ? 1.5 : 2.5) {
                ForEach(0..<p.total, id: \.self) { i in
                    Capsule().fill(i < p.done ? color : Palette.track).frame(height: height)
                }
            }
            .accessibilityLabel("\(p.done) of \(p.total) \(p.unit)")
        } else {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(color).frame(width: max(height, g.size.width * CGFloat(card.percent) / 100))
                }
            }
            .frame(height: height)
            .accessibilityLabel("\(card.percent) percent")
        }
    }
}

/// Overall progress as a ring with the percentage inside.
struct Ring: View {
    let value: Int
    var size: CGFloat = 34
    var color: Color = Palette.work

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: 4)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, value))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)").font(.system(size: size * 0.32, weight: .bold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Overall \(value) percent")
    }
}

/// Status dot: a solid dot with a soft halo while the agent is active. Deliberately not animated: a looping
/// animation keeps the menu bar window redrawing (and re-laying out) every frame, which costs real CPU.
struct PulsingDot: View {
    var color: Color
    var active: Bool

    var body: some View {
        ZStack {
            if active { Circle().fill(color.opacity(0.22)).frame(width: 13, height: 13) }
            Circle().fill(active ? color : color.opacity(0.45)).frame(width: 7, height: 7)
        }
        .frame(width: 13, height: 13)
    }
}

struct Chip: View {
    let text: String
    var color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(filled ? color : color.opacity(0.14)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A small labelled gauge for the machine strip.
struct Meter: View {
    let icon: String
    let label: String
    let value: String
    let fraction: Double          // how full / busy, 0...1
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(color).frame(width: max(3, g.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var color: Color = .secondary
    var fill = true

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(color)
            if let count { Text("\(count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(color) }
            if fill { Spacer() }
        }
    }
}

/// Plain borderless button with a hover highlight, used for row actions.
struct SoftButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .primary
    var prominent = false
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? .white : tint)
            .padding(.horizontal, 8).padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? tint.opacity(hover ? 0.85 : 1) : tint.opacity(hover ? 0.2 : 0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)          // dimmed, not swapped for a spinner, so nothing reflows while sending
        .animation(.easeOut(duration: 0.15), value: busy)
    }
}

enum Fmt {
    static func idle(_ minutes: Int) -> String {
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "calling now" }
        if s < 60 { return "call in \(s)s" }
        return "call in \(s / 60)m"
    }

    /// Feed times: "now", "12m", "3h", "yesterday", or a weekday.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if Calendar.current.isDateInToday(date) { return "\(s / 3600)h" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: date)
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
