import SwiftUI

/// Teammates: linked Agent Watches on this network, a pairing card while linking, and Connect.
struct TeammatesSection: View {
    @EnvironmentObject var peers: PeerService
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Teammates", count: peers.peers.isEmpty ? nil : peers.peers.count, fill: false)
                Spacer()
                Button { withAnimation(.snappy) { choosing.toggle() } } label: {
                    Label(choosing ? "Done" : "Connect", systemImage: choosing ? "xmark" : "person.badge.plus")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.work)
                .help("Link with a teammate's Agent Watch on this network")
            }
            if let p = peers.pairing { PairingCard(pairing: p) }
            if choosing && peers.pairing == nil { NearbyList(close: { choosing = false }) }
            if peers.peers.isEmpty && !choosing && peers.pairing == nil {
                Text("Link with teammates on the same Wi-Fi to see each other's agents and message each other's coordinators. Nothing leaves your local network.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(peers.peers) { TeammateRow(peer: $0) }
            if let n = peers.notice {
                Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .task(id: n) { try? await Task.sleep(for: .seconds(5)); if peers.notice == n { peers.notice = nil } }
            }
        }
    }
}

private struct NearbyList: View {
    @EnvironmentObject var peers: PeerService
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let candidates = peers.nearby.filter { n in !peers.peers.contains { $0.id == n.id } }
            if candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Agent Watch on this network… Both Macs need to be on the same Wi-Fi with Agent Watch open.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(candidates) { n in
                HStack(spacing: 8) {
                    Avatar(name: n.name)
                    Text(n.name).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    SoftButton(title: "Link", icon: "link", tint: Palette.work, prominent: true) { peers.startPairing(n); close() }
                }
            }
        }
        .padding(10)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
    }
}

/// Both people compare the code; it only links when both say it matches.
private struct PairingCard: View {
    let pairing: PairingView
    @EnvironmentObject var peers: PeerService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pairing.incoming ? "\(pairing.peerName) wants to link" : "Linking with \(pairing.peerName)")
                .font(.system(size: 13, weight: .semibold))
            if let code = pairing.code {
                Text(code)
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit().tracking(2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Pairing code \(code)")
                Text(pairing.localConfirmed
                     ? "Waiting for \(pairing.peerName) to confirm…"
                     : "Check that \(pairing.peerName)'s screen shows exactly this code. Only confirm if it matches.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !pairing.localConfirmed {
                        SoftButton(title: "It matches", icon: "checkmark", tint: Palette.done, prominent: true) { peers.confirmPairing() }
                    }
                    SoftButton(title: pairing.localConfirmed ? "Cancel" : "Doesn't match", icon: "xmark") { peers.cancelPairing() }
                    Spacer()
                    if pairing.remoteConfirmed {
                        Label("They confirmed", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.done)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    SoftButton(title: "Cancel", icon: "xmark") { peers.cancelPairing() }
                }
            }
        }
        .padding(12)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.work.opacity(0.6), lineWidth: 1.5))
    }
}

/// A linked teammate: online state, their agents at a glance, messages, what you share, unlink.
private struct TeammateRow: View {
    let peer: PeerRecord
    @EnvironmentObject var peers: PeerService
    @State private var expanded = false
    @State private var draft = ""

    var body: some View {
        let status = peers.statuses[peer.id]
        let isOnline = peers.online.contains(peer.id)
        let unread = peers.unread[peer.id] ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                if expanded { peers.unread[peer.id] = 0 }
            } label: {
                HStack(spacing: 9) {
                    Avatar(name: peer.name, online: isOnline)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(peer.name).font(.system(size: 12.5, weight: .semibold))
                            if unread > 0 { Chip(text: "\(unread) NEW", color: Palette.work, filled: true) }
                        }
                        Text(summary(status, online: isOnline)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let cards = status?.cards, !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(cards.prefix(8).enumerated()), id: \.offset) { _, c in
                            HStack(spacing: 7) {
                                Circle().fill(c.state == "needs" ? Palette.needs : c.state == "done" ? Palette.done : Palette.work)
                                    .frame(width: 6, height: 6)
                                Text(c.title).font(.system(size: 11.5)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(c.progress ?? (c.pct.map { "\($0)%" } ?? "")).font(.system(size: 11, design: .rounded))
                                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                let msgs = peers.messages[peer.id] ?? []
                if !msgs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(msgs.suffix(4)) { m in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.incoming ? m.from : "You → \(peer.name)").font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(m.incoming ? Palette.work : .secondary)
                                Text(m.text).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                HStack(spacing: 6) {
                    TextField("Message \(peer.name)…", text: $draft)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline))
                        .onSubmit(send)
                        .onKeyPress(.return, phases: .down) { _ in send(); return .handled }
                }
                HStack(spacing: 8) {
                    Text("You share").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { peer.share }, set: { peers.setShare(peer.id, $0) })) {
                        Text("Counts").tag("counts")
                        Text("Summary").tag("summary")
                        Text("Detail").tag("detail")
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    .help("Counts: how many agents need you / are working. Summary: plus their titles and progress. Detail: plus what each is doing.")
                    Spacer()
                    Button("Unlink") { peers.unlink(peer.id) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.needs)
                }
            }
        }
        .padding(10)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline))
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        peers.send(to: peer.id, text: draft, from: peers.myName)
        draft = ""
    }

    private func summary(_ s: PeerStatus?, online: Bool) -> String {
        guard let s else { return online ? "Online" : "Offline" }
        var parts: [String] = []
        if s.needs > 0 { parts.append("\(s.needs) need\(s.needs == 1 ? "s" : "") them") }
        parts.append("\(s.working) working")
        if !online { parts.append("offline") }
        return parts.joined(separator: " · ")
    }
}

struct Avatar: View {
    let name: String
    var online: Bool? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle().fill(Palette.work.opacity(0.85)).frame(width: 24, height: 24)
                .overlay(Text(String(name.prefix(1)).uppercased()).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white))
            if let online {
                Circle().fill(online ? Palette.done : Color(nsColor: .systemGray)).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Palette.cardFill, lineWidth: 1.5))
            }
        }
    }
}
