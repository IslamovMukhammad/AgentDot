import Foundation
import Network

/// Receives Claude Code hook events and statusLine updates on a Unix domain socket.
///
/// The hook scripts (`ClaudeHooks`) post a small JSON body with `curl --unix-socket`, in the
/// background, so Claude Code is never slowed down. Two paths:
///   `/claude-event`  one hook event (session state)
///   `/claude-limits` one statusLine update (plan limits, context %)
///
/// Why a Unix socket and not a TCP port: a web page can send requests to 127.0.0.1 but has no
/// way to reach a socket file, and the socket lives in Application Support/AgentDot (0700),
/// so no other user on the Mac can connect to it or squat on it. On top of that every request
/// must carry the per-install token, be `application/json`, and have no `Origin` header (only
/// browsers send one). Bodies over 1 MB and headers over 16 KB are refused.
final class EventServer {

    static var socketURL: URL { AppSupport.directory.appendingPathComponent("agentdot.sock") }
    nonisolated static let tokenHeader = "x-hook-token"
    nonisolated static let paths: Set<String> = ["/claude-event", "/claude-limits"]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "AgentDot.events")
    /// (path, JSON object). Called on the main actor.
    var onRequest: ((String, [String: Any]) -> Void)?
    /// Where the expected token comes from (tests point it elsewhere).
    var tokenProvider: () -> String? = { ClaudeHooks.currentToken() }
    private(set) var lastError: String?
    private var socketPath: String?

    func start(socketPath: String = EventServer.socketURL.path) {
        stop()
        // A socket file left by a previous run (or a crash) would make bind fail.
        unlink(socketPath)
        self.socketPath = socketPath
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .unix(path: socketPath)
            let listener = try NWListener(using: params)
            let queue = self.queue
            listener.newConnectionHandler = { [weak self] connection in
                Self.receive(on: connection, buffer: Data()) { request in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.deliver(request) }
                    }
                }
                connection.start(queue: queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    // Only you may connect, even if the folder's permissions were ever loosened.
                    chmod(socketPath, 0o600)
                case .failed(let error):
                    let text = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.lastError = text }
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let socketPath { unlink(socketPath) }
        socketPath = nil
    }

    private func deliver(_ request: HTTPRequest) {
        guard Self.accepts(request, token: tokenProvider()) else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else { return }
        onRequest?(request.path, Self.compact(object))
    }

    /// The hook script sends every field, empty when it has nothing; empty means absent.
    nonisolated static func compact(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.compactMapValues { value in
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let nested = value as? [String: Any] {
                let inner = compact(nested)
                return inner.isEmpty ? nil : inner
            }
            return value
        }
    }

    /// The access rules, pure so they are unit-tested.
    nonisolated static func accepts(_ request: HTTPRequest, token: String?) -> Bool {
        guard request.method == "POST", paths.contains(request.path) else { return false }
        // Browsers always send Origin on a cross-site POST; the hook script never does.
        guard request.headers["origin"] == nil else { return false }
        let type = request.headers["content-type"]?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { return false }
        guard let token, !token.isEmpty, let sent = request.headers[tokenHeader] else { return false }
        return constantTimeEqual(sent, token)
    }

    nonisolated private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Reads one request, answers, closes. Never more than the parser's limits.
    nonisolated private static func receive(on connection: NWConnection, buffer: Data,
                                            completion: @escaping @Sendable (HTTPRequest) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                completion(request)
                respond(connection, status: "204 No Content")
            case .incomplete where error == nil && !isComplete:
                receive(on: connection, buffer: buffer, completion: completion)
            case .tooLarge:
                respond(connection, status: "413 Payload Too Large")
            default:
                respond(connection, status: "400 Bad Request")
            }
        }
    }

    nonisolated private static func respond(_ connection: NWConnection, status: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Minimal HTTP/1.1 request parsing: request line, headers, `Content-Length` body. Unit-tested.
nonisolated struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024

    enum Parse: Equatable {
        case complete(HTTPRequest)
        case incomplete
        case invalid
        case tooLarge
    }

    static func parse(_ data: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maxHeaderBytes else { return .tooLarge }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else { return .invalid }
            guard value <= maxBodyBytes else { return .tooLarge }
            length = value
        }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                                     headers: headers, body: body))
    }
}
