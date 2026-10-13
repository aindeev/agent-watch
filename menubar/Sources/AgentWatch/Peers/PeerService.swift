import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import UserNotifications

// Teammate links: other Agent Watch instances on the same local network. Discovery is Bonjour
// (_agentwatch._tcp), pairing is a 6-digit code both people confirm, and every later connection is a mutually
// authenticated, encrypted session (see Crypto.swift). Nothing goes through a server or the internet.
//
// What a teammate can do is deliberately small:
//   - see what you share: counts only, a summary (titles, states, progress) or detail (plus each agent's current
//     step), chosen per teammate;
//   - send messages to you and your coordinator, which arrive labelled as theirs and are never instructions.
// A teammate can never answer your agents, pause your calls or act on anything; their messages are information.
//
// The coordinator talks to this through files in <claude-watcher>/peers/ (see coord.py peer):
//   peers.json, status/<id>.json, inbox.jsonl     written here
//   outbox/*.json                                 written by coord.py, sent from here, results in outbox.log

struct PeerRecord: Codable, Identifiable, Hashable {
    var id: String              // fingerprint of their identity key
    var name: String
    var publicKey: String       // base64 Ed25519
    var share: String           // counts | summary | detail: what *I* share with them
    var pairedAt: Double
    var lastSeen: Double?
    var lastHost: String?       // last address that worked, to reconnect without Bonjour
}

struct PeerCard: Codable, Hashable {
    var title: String
    var state: String           // needs | working | done
    var progress: String?
    var pct: Int?
    var detail: String?
}

struct PeerStatus: Codable, Hashable {
    var needs: Int
    var working: Int
    var done: Int
    var cards: [PeerCard]
    var at: Double
}

struct PeerMessage: Codable, Hashable, Identifiable {
    var id: String
    var peer: String
    var from: String
    var text: String
    var at: Double
    var incoming: Bool
}

struct Nearby: Hashable, Identifiable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
}

struct PairingView: Equatable {
    var peerName: String
    var code: String?           // nil until both nonces are in
    var incoming: Bool
    var localConfirmed = false
    var remoteConfirmed = false
}

@MainActor
final class PeerService: ObservableObject {
    @Published private(set) var peers: [PeerRecord] = []
    @Published private(set) var online: Set<String> = []
    @Published private(set) var statuses: [String: PeerStatus] = [:]
    @Published private(set) var messages: [String: [PeerMessage]] = [:]
    @Published var unread: [String: Int] = [:]
    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var pairing: PairingView?
    @Published var notice: String?

    let identity: Identity
    let myName: String
    let home: URL
    private weak var store: Store?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [String: Link] = [:]                 // peer id -> authenticated session
    private var unauthenticated: [ObjectIdentifier: Link] = [:]
    private var pair: PairState?
    private var timers: [Timer] = []
    private var watch: AnyCancellable?
    private var recent: [String: [Double]] = [:]            // peer id -> recent incoming message times (rate limit)
    private var queued: [String: [[String: Any]]] = [:]     // messages waiting for a peer to come online
    private let port: NWEndpoint.Port

    private final class PairState {
        let incoming: Bool
        let link: Link
        var peerName = ""
        var peerKey = Data()
        let myNonce = PeerCrypto.random()
        var theirNonce = Data()
        var commit = Data()
        var code: String?
        var localConfirmed = false
        var remoteConfirmed = false
        let started = Date()
        init(incoming: Bool, link: Link) { self.incoming = incoming; self.link = link }
    }

    init(store: Store?) {
        self.store = store
        let env = ProcessInfo.processInfo.environment
        home = env["AGENTWATCH_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentWatch")
        identity = Identity.load(dir: home)
        myName = env["AGENTWATCH_NAME"] ?? PeerService.userName(root: store?.root) ?? NSFullUserName()
        port = env["AGENTWATCH_PORT"].flatMap { UInt16($0) }.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        peers = loadPeers()
    }

    /// USER_NAME from claude-watcher's .env, the name the phone agent uses for you.
    nonisolated static func userName(root: URL?) -> String? {
        guard let root, let env = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        guard let line = env.split(separator: "\n").first(where: { $0.hasPrefix("USER_NAME=") }) else { return nil }
        let v = line.dropFirst(10).split(separator: "#")[0].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    // MARK: lifecycle

    func start() {
        startListener()
        startBrowser()
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainOutbox() }
        })
        // share my status when it changes (debounced) and every 30 s as a heartbeat
        watch = store?.$snap.debounce(for: .seconds(2), scheduler: RunLoop.main).sink { [weak self] _ in self?.broadcastStatus() }
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcastStatus() }
        })
        writeBridge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        guard let l = try? NWListener(using: params, on: port) else { notice = "Couldn't listen for teammates"; return }
        l.service = NWListener.Service(name: "\(myName) · Agent Watch", type: "_agentwatch._tcp", domain: nil,
                                       txtRecord: NWTXTRecord(["id": identity.id, "v": "1"]))
        l.newConnectionHandler = { [weak self] conn in
            MainActor.assumeIsolated { self?.accept(conn) }
        }
        l.start(queue: .main)
        listener = l
    }

    private func startBrowser() {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_agentwatch._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nearby = results.compactMap { r in
                    guard case let .bonjour(txt) = r.metadata, let id = txt["id"], id != self.identity.id else { return nil }
                    var name = "Agent Watch"
                    if case let .service(n, _, _, _) = r.endpoint { name = n.replacingOccurrences(of: " · Agent Watch", with: "") }
                    return Nearby(id: id, name: name, endpoint: r.endpoint)
                }
                self.tick()
            }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Reconnects to paired teammates that aren't linked, and expires a stale pairing.
    private func tick() {
        if let p = pair, Date().timeIntervalSince(p.started) > 180 { cancelPairing(reason: "Pairing timed out") }
        for peer in peers where links[peer.id] == nil {
            // the side with the smaller id dials, so two Macs don't race each other; the other dials as a fallback
            // only when it can't see the first on Bonjour (it may be the only one able to reach out)
            let seen = nearby.first { $0.id == peer.id }
            guard identity.id < peer.id || seen == nil else { continue }
            if let seen { dial(seen.endpoint, peer: peer) }
            else if let host = peer.lastHost, let ep = Self.endpoint(host) { dial(ep, peer: peer) }
        }
    }

    nonisolated static func endpoint(_ hostPort: String) -> NWEndpoint? {
        guard let i = hostPort.lastIndex(of: ":"), let p = UInt16(hostPort[hostPort.index(after: i)...]),
              let port = NWEndpoint.Port(rawValue: p) else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(hostPort[..<i])), port: port)
    }

    // MARK: connections

    private func accept(_ conn: NWConnection) {
        let link = Link(conn, outbound: false, queue: .main)
        track(link)
        link.start()
    }

    private func track(_ link: Link) {
        unauthenticated[ObjectIdentifier(link)] = link
        link.onFrame = { [weak self] l, f in MainActor.assumeIsolated { self?.frame(l, f) } }
        link.onClose = { [weak self] l in MainActor.assumeIsolated { self?.closed(l) } }
        // a connection that hasn't authenticated or started pairing within 15 s is dropped
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak link] in
            guard let self, let link, self.unauthenticated[ObjectIdentifier(link)] != nil, link.peerId == nil,
                  self.pair?.link !== link else { return }
            link.close()
        }
    }

    private var dialing: Set<String> = []
    private var sessionEphemeral: [ObjectIdentifier: Curve25519.KeyAgreement.PrivateKey] = [:]

    private func dial(_ endpoint: NWEndpoint, peer: PeerRecord) {
        guard !dialing.contains(peer.id) else { return }
        dialing.insert(peer.id)
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let link = Link(NWConnection(to: endpoint, using: params), outbound: true, queue: .main)
        link.peerId = nil
        track(link)
        let eph = Curve25519.KeyAgreement.PrivateKey()
        sessionEphemeral[ObjectIdentifier(link)] = eph
        expected[ObjectIdentifier(link)] = peer.id
        link.start()
        link.send(["t": "hello", "key": identity.publicKey.base64EncodedString(), "eph": eph.publicKey.rawRepresentation.base64EncodedString()])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.dialing.remove(peer.id) }
    }

    private var expected: [ObjectIdentifier: String] = [:]   // outbound link -> the peer id it must turn out to be

    private func closed(_ link: Link) {
        unauthenticated[ObjectIdentifier(link)] = nil
        sessionEphemeral[ObjectIdentifier(link)] = nil
        expected[ObjectIdentifier(link)] = nil
        if let id = link.peerId, links[id] === link {
            links[id] = nil
            online.remove(id)
            writeBridge()
        }
        if pair?.link === link, pairing != nil, !(pair!.localConfirmed && pair!.remoteConfirmed) {
            pair = nil
            pairing = nil
            notice = "The other Mac closed the connection"
        }
    }

    // MARK: frames

    private func frame(_ link: Link, _ f: [String: Any]) {
        guard let t = f["t"] as? String else { link.close(); return }
        if link.peerId == nil {
            switch t {
            case "pair1", "pair2", "pair3", "pair_ok", "pair_no", "busy": pairingFrame(link, t, f)
            case "hello": serverHello(link, f)
            case "hello2": clientHello2(link, f)
            case "hello3": serverHello3(link, f)
            default: link.close()
            }
            return
        }
        guard let peer = link.peerId else { return }
        switch t {
        case "status":
            guard let data = try? JSONSerialization.data(withJSONObject: f["status"] ?? [:]),
                  var s = try? JSONDecoder().decode(PeerStatus.self, from: data) else { return }
            s.cards = Array(s.cards.prefix(50))
            statuses[peer] = s
            touch(peer)
            writeBridge()
        case "msg": incomingMessage(peer, f)
        case "revoke":
            removePeer(peer, tell: false)
            notice = "A teammate unlinked from you"
        case "ping": break
        default: break
        }
    }

    // MARK: pairing

    /// Starts linking with a nearby Agent Watch: both screens will show a 6-digit code to compare.
    func startPairing(_ target: Nearby) { startPairing(endpoint: target.endpoint, name: target.name) }

    func startPairing(endpoint: NWEndpoint, name: String) {
        guard pair == nil else { notice = "Finish the current pairing first"; return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let link = Link(NWConnection(to: endpoint, using: params), outbound: true, queue: .main)
        track(link)
        let p = PairState(incoming: false, link: link)
        p.peerName = name
        pair = p
        pairing = PairingView(peerName: name, code: nil, incoming: false)
        link.start()
        link.send(["t": "pair1", "name": myName, "key": identity.publicKey.base64EncodedString(),
                   "commit": PeerCrypto.sha256(p.myNonce).base64EncodedString()])
    }

    private func pairingFrame(_ link: Link, _ t: String, _ f: [String: Any]) {
        func b64(_ k: String) -> Data? { (f[k] as? String).flatMap { Data(base64Encoded: $0) } }
        switch t {
        case "pair1":   // someone wants to link with me
            guard pair == nil else { link.send(["t": "busy"]); link.close(); return }
            guard let key = b64("key"), key.count == 32, let commit = b64("commit"), commit.count == 32,
                  let name = (f["name"] as? String)?.prefix(60) else { link.close(); return }
            let p = PairState(incoming: true, link: link)
            p.peerName = String(name)
            p.peerKey = key
            p.commit = commit
            pair = p
            pairing = PairingView(peerName: p.peerName, code: nil, incoming: true)
            link.send(["t": "pair2", "name": myName, "key": identity.publicKey.base64EncodedString(), "nonce": p.myNonce.base64EncodedString()])
        case "pair2":   // they answered my request
            guard let p = pair, p.link === link, !p.incoming, let key = b64("key"), key.count == 32,
                  let nonce = b64("nonce"), nonce.count == 32 else { link.close(); return }
            p.peerKey = key
            p.theirNonce = nonce
            if let n = f["name"] as? String { p.peerName = String(n.prefix(60)) }
            link.send(["t": "pair3", "nonce": p.myNonce.base64EncodedString()])
            p.code = PeerCrypto.sas(idI: identity.publicKey, idR: key, nonceI: p.myNonce, nonceR: nonce)
            publishPairing()
        case "pair3":   // they revealed the nonce they committed to
            guard let p = pair, p.link === link, p.incoming, let nonce = b64("nonce"),
                  PeerCrypto.sha256(nonce) == p.commit else { cancelPairing(reason: "Pairing failed a security check"); return }
            p.theirNonce = nonce
            p.code = PeerCrypto.sas(idI: p.peerKey, idR: identity.publicKey, nonceI: nonce, nonceR: p.myNonce)
            publishPairing()
            notify(title: "\(p.peerName) wants to link Agent Watch", body: "Check both screens show \(p.code!).")
        case "pair_ok":
            guard let p = pair, p.link === link, p.code != nil else { return }
            p.remoteConfirmed = true
            publishPairing()
            finishPairingIfReady()
        case "pair_no":
            guard pair?.link === link else { return }
            pair = nil
            pairing = nil
            notice = "They declined, or their code didn't match"
            link.close()
        case "busy":
            pair = nil
            pairing = nil
            notice = "That Mac is in the middle of another pairing"
            link.close()
        default: break
        }
    }

    private func publishPairing() {
        guard let p = pair else { pairing = nil; return }
        pairing = PairingView(peerName: p.peerName, code: p.code, incoming: p.incoming,
                              localConfirmed: p.localConfirmed, remoteConfirmed: p.remoteConfirmed)
    }

    /// The person here says the codes match.
    func confirmPairing() {
        guard let p = pair, p.code != nil else { return }
        p.localConfirmed = true
        p.link.send(["t": "pair_ok"])
        publishPairing()
        finishPairingIfReady()
    }

    func cancelPairing(reason: String? = nil) {
        guard let p = pair else { return }
        p.link.send(["t": "pair_no"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { p.link.close() }
        pair = nil
        pairing = nil
        if let reason { notice = reason }
    }

    private func finishPairingIfReady() {
        guard let p = pair, p.localConfirmed, p.remoteConfirmed else { return }
        let id = PeerCrypto.fingerprint(p.peerKey)
        var host: String?
        if case let .hostPort(h, port)? = p.link.conn.currentPath?.remoteEndpoint, !p.incoming { host = "\(h):\(port)" }
        peers.removeAll { $0.id == id }
        peers.append(PeerRecord(id: id, name: p.peerName, publicKey: p.peerKey.base64EncodedString(), share: "summary",
                                pairedAt: Date().timeIntervalSince1970, lastSeen: nil, lastHost: host))
        savePeers()
        notice = "Linked with \(p.peerName)"
        pair = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            p.link.close()
            self?.pairing = nil
            self?.tick()
        }
        writeBridge()
    }

    // MARK: sessions

    private func record(forKey key: Data) -> PeerRecord? {
        let id = PeerCrypto.fingerprint(key)
        return peers.first { $0.id == id && Data(base64Encoded: $0.publicKey) == key }
    }

    private func serverHello(_ link: Link, _ f: [String: Any]) {
        guard !link.outbound, let key = (f["key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let ePubC = (f["eph"] as? String).flatMap({ Data(base64Encoded: $0) }), ePubC.count == 32,
              record(forKey: key) != nil, let cPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubC)
        else { link.close(); return }   // unknown keys learn nothing, not even a reason
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ePubS = eph.publicKey.rawRepresentation
        let t = PeerCrypto.transcript(idC: key, idS: identity.publicKey, eC: ePubC, eS: ePubS)
        guard let sig = try? identity.sign(t + Data("server".utf8)), let secret = try? eph.sharedSecretFromKeyAgreement(with: cPub)
        else { link.close(); return }
        link.send(["t": "hello2", "key": identity.publicKey.base64EncodedString(), "eph": ePubS.base64EncodedString(),
                   "sig": sig.base64EncodedString()])
        pendingServer[ObjectIdentifier(link)] = (key, t, PeerCrypto.sessionKeys(secret, transcript: t))
    }

    private var pendingServer: [ObjectIdentifier: (key: Data, transcript: Data, keys: (c2s: SymmetricKey, s2c: SymmetricKey))] = [:]

    private func serverHello3(_ link: Link, _ f: [String: Any]) {
        guard let pend = pendingServer.removeValue(forKey: ObjectIdentifier(link)),
              let sig = (f["sig"] as? String).flatMap({ Data(base64Encoded: $0) }),
              Identity.verify(sig, pend.transcript + Data("client".utf8), publicKey: pend.key) else { link.close(); return }
        link.channel = SecureChannel(send: pend.keys.s2c, receive: pend.keys.c2s)
        authenticated(link, peer: PeerCrypto.fingerprint(pend.key))
    }

    private func clientHello2(_ link: Link, _ f: [String: Any]) {
        let lid = ObjectIdentifier(link)
        guard link.outbound, let want = expected[lid], let eph = sessionEphemeral[lid],
              let key = (f["key"] as? String).flatMap({ Data(base64Encoded: $0) }), PeerCrypto.fingerprint(key) == want,
              record(forKey: key) != nil,
              let ePubS = (f["eph"] as? String).flatMap({ Data(base64Encoded: $0) }), ePubS.count == 32,
              let sig = (f["sig"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let sPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubS) else { link.close(); return }
        let t = PeerCrypto.transcript(idC: identity.publicKey, idS: key, eC: eph.publicKey.rawRepresentation, eS: ePubS)
        guard Identity.verify(sig, t + Data("server".utf8), publicKey: key),
              let mySig = try? identity.sign(t + Data("client".utf8)),
              let secret = try? eph.sharedSecretFromKeyAgreement(with: sPub) else { link.close(); return }
        link.send(["t": "hello3", "sig": mySig.base64EncodedString()])
        let keys = PeerCrypto.sessionKeys(secret, transcript: t)
        link.channel = SecureChannel(send: keys.c2s, receive: keys.s2c)
        if case let .hostPort(h, p)? = link.conn.currentPath?.remoteEndpoint, let i = peers.firstIndex(where: { $0.id == want }) {
            peers[i].lastHost = "\(h):\(p)"
            savePeers()
        }
        authenticated(link, peer: want)
    }

    private func authenticated(_ link: Link, peer: String) {
        unauthenticated[ObjectIdentifier(link)] = nil
        sessionEphemeral[ObjectIdentifier(link)] = nil
        expected[ObjectIdentifier(link)] = nil
        dialing.remove(peer)
        // two Macs that dialled each other at once: keep the connection the smaller id opened
        if let existing = links[peer], !existing.isClosed {
            let keepNew = (link.outbound && identity.id < peer) || (!link.outbound && peer < identity.id)
            if !keepNew { link.close(); return }
            existing.peerId = nil
            existing.close()
        }
        link.peerId = peer
        links[peer] = link
        online.insert(peer)
        touch(peer)
        sendStatus(to: peer)
        for m in queued.removeValue(forKey: peer) ?? [] { link.send(m) }
        writeBridge()
    }

    private func touch(_ peer: String) {
        guard let i = peers.firstIndex(where: { $0.id == peer }) else { return }
        peers[i].lastSeen = Date().timeIntervalSince1970
    }

    // MARK: sharing

    func setShare(_ peer: String, _ level: String) {
        guard ["counts", "summary", "detail"].contains(level), let i = peers.firstIndex(where: { $0.id == peer }) else { return }
        peers[i].share = level
        savePeers()
        sendStatus(to: peer)
        writeBridge()
    }

    private func broadcastStatus() { for id in links.keys { sendStatus(to: id) } }

    /// Only what this teammate's share level allows; never transcripts, never what an agent asked of you in detail
    /// unless you chose "detail".
    func status(for level: String) -> PeerStatus {
        let snap = store?.snap ?? Snapshot()
        var cards: [PeerCard] = []
        if level != "counts" {
            for a in snap.asks {
                cards.append(PeerCard(title: a.title, state: "needs", progress: nil, pct: a.card?.percent,
                                      detail: level == "detail" ? String(a.text.prefix(200)) : nil))
            }
            for c in snap.working + snap.finished {
                cards.append(PeerCard(title: c.label, state: c.state == "done" ? "done" : "working",
                                      progress: c.countable.map { "\($0.done)/\($0.total) \($0.unit)" }, pct: c.percent,
                                      detail: level == "detail" ? c.doing.map { String($0.prefix(200)) } : nil))
            }
        }
        return PeerStatus(needs: snap.asks.count, working: snap.working.count, done: snap.finished.count,
                          cards: cards, at: Date().timeIntervalSince1970)
    }

    private func sendStatus(to peer: String) {
        guard let link = links[peer], let rec = peers.first(where: { $0.id == peer }),
              let data = try? JSONEncoder().encode(status(for: rec.share)),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        link.send(["t": "status", "status": obj])
    }

    // MARK: messages

    /// Sends a message to a teammate's Agent Watch, where it shows to them and their coordinator.
    @discardableResult
    func send(to peer: String, text: String, from: String) -> String {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !t.isEmpty, peers.contains(where: { $0.id == peer }) else { return "unknown teammate" }
        let msg: [String: Any] = ["t": "msg", "id": UUID().uuidString, "from": String(from.prefix(80)), "text": t,
                                  "at": Date().timeIntervalSince1970]
        messages[peer, default: []].append(PeerMessage(id: msg["id"] as! String, peer: peer, from: from, text: t,
                                                       at: Date().timeIntervalSince1970, incoming: false))
        messages[peer] = Array(messages[peer]!.suffix(40))
        if let link = links[peer] { link.send(msg); return "sent" }
        queued[peer, default: []].append(msg)
        return "queued until they're online"
    }

    private func incomingMessage(_ peer: String, _ f: [String: Any]) {
        guard let text = f["text"] as? String, !text.isEmpty, text.count <= 4000 else { return }
        let now = Date().timeIntervalSince1970
        recent[peer] = (recent[peer] ?? []).filter { now - $0 < 60 } + [now]
        guard recent[peer]!.count <= 20 else { return }          // at most 20 a minute per teammate
        let name = peers.first { $0.id == peer }?.name ?? "A teammate"
        let from = (f["from"] as? String).map { String($0.prefix(80)) } ?? name
        let m = PeerMessage(id: (f["id"] as? String) ?? UUID().uuidString, peer: peer, from: from, text: text, at: now, incoming: true)
        messages[peer, default: []].append(m)
        messages[peer] = Array(messages[peer]!.suffix(40))
        unread[peer, default: 0] += 1
        touch(peer)
        notify(title: "\(name): \(from == name ? "message" : from)", body: String(text.prefix(200)))
        bridgeIncoming(m, peerName: name)
        writeBridge()
    }

    // MARK: unlinking

    func unlink(_ peer: String) { removePeer(peer, tell: true); notice = "Unlinked" }

    private func removePeer(_ peer: String, tell: Bool) {
        if let link = links[peer] {
            if tell { link.send(["t": "revoke"]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { link.close() }
        }
        links[peer] = nil
        online.remove(peer)
        peers.removeAll { $0.id == peer }
        statuses[peer] = nil
        queued[peer] = nil
        savePeers()
        writeBridge()
    }

    // MARK: persistence and the coordinator bridge

    private var peersFile: URL { home.appendingPathComponent("peers.json") }

    private func loadPeers() -> [PeerRecord] {
        guard let data = try? Data(contentsOf: peersFile) else { return [] }
        return (try? JSONDecoder().decode([PeerRecord].self, from: data)) ?? []
    }

    private func savePeers() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(peers) else { return }
        FileManager.default.createFile(atPath: peersFile.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private var bridge: URL? {
        guard let root = store?.root else { return nil }
        let dir = root.appendingPathComponent("peers")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("outbox"), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("status"), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    private func writeBridge() {
        guard let dir = bridge else { return }
        let list: [[String: Any]] = peers.map { p in
            var d: [String: Any] = ["id": p.id, "name": p.name, "online": online.contains(p.id), "share": p.share,
                                    "unread": unread[p.id] ?? 0]
            if let s = statuses[p.id] { d["needs"] = s.needs; d["working"] = s.working; d["done"] = s.done }
            if let seen = p.lastSeen { d["lastSeen"] = seen }
            return d
        }
        let me: [String: Any] = ["id": identity.id, "name": myName, "peers": list]
        if let data = try? JSONSerialization.data(withJSONObject: me, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("peers.json"), options: .atomic)
        }
        for (id, s) in statuses {
            if let data = try? JSONEncoder().encode(s) { try? data.write(to: dir.appendingPathComponent("status/\(id).json"), options: .atomic) }
        }
    }

    /// Incoming teammate messages go to the inbox and, as one line, to events.log, which the coordinator watches.
    private func bridgeIncoming(_ m: PeerMessage, peerName: String) {
        guard let dir = bridge, let root = store?.root else { return }
        let rec: [String: Any] = ["at": m.at, "peer": peerName, "peerId": m.peer, "from": m.from, "text": m.text]
        if let data = try? JSONSerialization.data(withJSONObject: rec) { append(data + Data("\n".utf8), to: dir.appendingPathComponent("inbox.jsonl")) }
        let oneLine = m.text.replacingOccurrences(of: "\n", with: " ").prefix(400)
        append(Data("PEER \(peerName) (\(m.from)): \(oneLine)\n".utf8), to: root.appendingPathComponent("events.log"))
    }

    private func append(_ data: Data, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }

    /// Sends what coord.py dropped in peers/outbox/, and records each result in peers/outbox.log.
    private func drainOutbox() {
        guard let dir = bridge else { return }
        let box = dir.appendingPathComponent("outbox")
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []).sorted() where f.hasSuffix(".json") {
            let url = box.appendingPathComponent(f)
            guard let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let to = (o["to"] as? String)?.lowercased(), let text = o["text"] as? String else {
                try? FileManager.default.removeItem(at: url); continue
            }
            let match = peers.filter { $0.id.hasPrefix(to) || $0.name.lowercased() == to || $0.name.lowercased().hasPrefix(to) }
            let result: String
            if match.count == 1 { result = send(to: match[0].id, text: text, from: (o["from"] as? String) ?? "\(myName)'s coordinator") }
            else { result = match.isEmpty ? "no teammate called \(to)" : "\(to) matches more than one teammate" }
            try? FileManager.default.removeItem(at: url)
            let line: [String: Any] = ["file": f, "to": to, "result": result, "at": Date().timeIntervalSince1970]
            if let d = try? JSONSerialization.data(withJSONObject: line) { append(d + Data("\n".utf8), to: dir.appendingPathComponent("outbox.log")) }
        }
    }

    private func notify(title: String, body: String) {
        guard Store.canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: test hooks

    var linkedCount: Int { links.count }
}
