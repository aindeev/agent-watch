import Foundation
import Network

/// One TCP connection to another Agent Watch: length-prefixed frames, plain JSON during the handshake and
/// ChaChaPoly-sealed once a SecureChannel is set. Callbacks run on the PeerService queue.
final class Link {
    static let maxFrame = 256 * 1024
    static let debug = ProcessInfo.processInfo.environment["AGENTWATCH_DEBUG"] != nil
    func log(_ s: String) { if Link.debug { print("link \(outbound ? "out" : "in ") \(conn.endpoint): \(s)"); fflush(stdout) } }

    let conn: NWConnection
    let outbound: Bool
    var channel: SecureChannel?
    var peerId: String?                     // set once the peer is authenticated
    var onFrame: ((Link, [String: Any]) -> Void)?
    var onClose: ((Link) -> Void)?
    private var closed = false
    private let queue: DispatchQueue

    init(_ conn: NWConnection, outbound: Bool, queue: DispatchQueue) {
        self.conn = conn
        self.outbound = outbound
        self.queue = queue
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.log("state \(state)")
            switch state {
            case .ready:
                // a connection that arrives from (or resolves to) outside the local network is dropped
                if let remote = self.conn.currentPath?.remoteEndpoint, !LocalOnly.allowed(remote) {
                    self.log("refused non-local \(remote)"); self.close(); return
                }
                self.readFrame()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ obj: [String: Any]) {
        guard !closed, let json = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var body = json
        if let channel {
            guard let sealed = try? channel.seal(json) else { close(); return }
            body = sealed
        }
        var len = UInt32(body.count).bigEndian
        conn.send(content: Data(bytes: &len, count: 4) + body, completion: .contentProcessed { _ in })
    }

    private func readFrame() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, done, err in
            guard let self, let head, head.count == 4, err == nil else { self?.close(); return }
            let n = Int(head.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard n > 0, n <= Link.maxFrame else { self.close(); return }
            self.conn.receive(minimumIncompleteLength: n, maximumLength: n) { body, _, _, err in
                guard let body, body.count == n, err == nil else { self.close(); return }
                var plain = body
                if let channel = self.channel {
                    // anything altered, replayed or out of order fails here and ends the link
                    guard let opened = try? channel.open(body) else { self.close(); return }
                    plain = opened
                }
                guard let obj = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { self.close(); return }
                self.log("frame \(obj["t"] ?? "?")")
                self.onFrame?(self, obj)
                if !self.closed { self.readFrame() }
            }
            if done { self.close() }
        }
    }

    func close() {
        guard !closed else { return }
        log("close")
        closed = true
        conn.cancel()
        onClose?(self)
    }

    var isClosed: Bool { closed }
}

/// Teammate links never leave the local network: private IPv4 ranges, link-local, unique-local IPv6 and loopback.
enum LocalOnly {
    static func allowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return true }   // Bonjour names resolve to a host:port first
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 4 else { return false }
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
                || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            let b = [UInt8](a.rawValue)
            guard b.count == 16 else { return false }
            if a == .loopback { return true }
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }        // fe80::/10 link-local
            if (b[0] & 0xfe) == 0xfc { return true }                         // fc00::/7 unique local
            // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 part
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff,
               let v4 = IPv4Address(Data(b[12..<16])) {
                return allowed(.hostPort(host: .ipv4(v4), port: 1))
            }
            return false
        case .name: return false
        @unknown default: return false
        }
    }
}
