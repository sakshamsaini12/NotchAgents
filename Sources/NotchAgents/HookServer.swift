import Foundation
import Network
import Security

/// Minimal localhost HTTP server that receives Claude Code hook payloads.
/// PermissionRequest connections are held open until the user decides in the notch.
final class HookServer {
    struct Request {
        let query: [String: String]
        let token: String
        let headers: [String: String]
        let body: [String: Any]
    }

    /// Requests are small JSON hook payloads; anything bigger is dropped rather than buffered.
    private static let maxRequest = 8 << 20

    /// Per-install secret in ~/.notchagents/token (0600). Only the hook script can read it,
    /// so other local processes can't spoof events or approve permissions.
    /// Also written as a ready-made header file (`token.header`), so scripts can pass it with
    /// `curl -H @file` instead of on the command line, where `ps` would show it to every user.
    static let token: String = {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".notchagents")
        let file = dir.appendingPathComponent("token"), header = dir.appendingPathComponent("token.header")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Owner-only, even if the folder or file was created (or loosened) by something else.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var t = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.count < 32 || !t.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("no secure random") }
            t = bytes.map { String(format: "%02x", $0) }.joined()
            fm.createFile(atPath: file.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        fm.createFile(atPath: header.path, contents: Data("X-Notch-Token: \(t)\n".utf8), attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: header.path)
        return t
    }()

    /// Constant-time comparison, so response timing doesn't reveal how much of a guess matched.
    static func isValid(_ candidate: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A connection must deliver a complete request within this time; held approvals are exempt.
    private static let requestTimeout: TimeInterval = 10
    /// Open connections at once (held approvals included); more are refused.
    private static let maxConnections = 64
    private var open = 0

    var onRequest: ((Request, @escaping (Data?) -> Void) -> Void)?
    /// true once listening, false if the port couldn't be bound (e.g. another copy is running).
    var onState: ((Bool) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "notch.hooks", autoreleaseFrequency: .workItem)

    func start(port: UInt16 = 47823) {
        _ = Self.token
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { DispatchQueue.main.async { self.onState?(false) }; return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        // Bind failures (port in use) arrive asynchronously as .failed, not as a thrown error.
        l.stateUpdateHandler = { [weak self] state in
            let ok: Bool?
            switch state {
            case .ready: ok = true
            case .failed: ok = false
            default: ok = nil
            }
            if let ok { DispatchQueue.main.async { self?.onState?(ok) } }
        }
        l.start(queue: queue)
        listener = l
    }

    private final class Pending { var parsed = false, closed = false }

    private func handle(_ c: NWConnection) {
        guard open < Self.maxConnections else { c.cancel(); return }
        open += 1
        let pending = Pending()
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                // .failed can be followed by .cancelled: count the connection closed once.
                if !pending.closed { pending.closed = true; self?.open -= 1 }
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { if !pending.parsed { c.cancel() } }
        receive(c, buffer: Data(), pending: pending)
    }

    private func receive(_ c: NWConnection, buffer: Data, pending: Pending) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > Self.maxRequest { c.cancel(); return }
            if let req = self.parse(buf) {
                pending.parsed = true
                DispatchQueue.main.async {
                    self.onRequest?(req) { reply in
                        self.queue.async { self.respond(c, reply) }
                    }
                }
            } else if done || err != nil {
                c.cancel()
            } else {
                self.receive(c, buffer: buf, pending: pending)
            }
        }
    }

    private func parse(_ buf: Data) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = max(0, Int(headers["content-length"] ?? "") ?? 0)
        let token = headers["x-notch-token"] ?? ""
        let body = buf[sep.upperBound...]
        guard body.count >= length else { return nil }
        var query: [String: String] = [:]
        if let target = lines.first?.split(separator: " ").dropFirst().first,
           let comps = URLComponents(string: String(target)) {
            for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
        let json = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
        return Request(query: query, token: token, headers: headers, body: json)
    }

    private func respond(_ c: NWConnection, _ reply: Data?) {
        let payload = reply ?? Data()
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n"
        head += "Content-Length: \(payload.count)\r\n\r\n"
        var out = Data(head.utf8); out.append(payload)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
