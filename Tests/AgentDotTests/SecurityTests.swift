import Foundation
import Testing
@testable import AgentDot

/// A short temp folder: Unix socket paths must stay under 104 bytes.
func makeTempDir(_ prefix: String = "cm") throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func permissions(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

/// Waits (polling the main actor) until `condition` holds or the time is up.
func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@Suite("Hook receiver access rules")
struct ReceiverRuleTests {

    private func request(method: String = "POST", path: String = "/claude-event",
                         headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data("{}".utf8))
    }

    private let good = ["content-type": "application/json", "x-hook-token": "abc123"]

    @Test func acceptsOnlyTheRightRequest() {
        #expect(EventServer.accepts(request(headers: good), token: "abc123"))
        #expect(EventServer.accepts(request(path: "/claude-limits", headers: good), token: "abc123"))
        #expect(EventServer.accepts(request(headers: ["content-type": "application/json; charset=utf-8",
                                                      "x-hook-token": "abc123"]), token: "abc123"))
    }

    @Test func rejectsMissingOrWrongToken() {
        #expect(!EventServer.accepts(request(headers: ["content-type": "application/json"]), token: "abc123"))
        #expect(!EventServer.accepts(request(headers: ["content-type": "application/json", "x-hook-token": "abc124"]), token: "abc123"))
        #expect(!EventServer.accepts(request(headers: ["content-type": "application/json", "x-hook-token": "abc12"]), token: "abc123"))
        #expect(!EventServer.accepts(request(headers: ["content-type": "application/json", "x-hook-token": ""]), token: ""))
        // Hooks not installed: no token at all, so nothing is accepted.
        #expect(!EventServer.accepts(request(headers: good), token: nil))
    }

    @Test func rejectsBrowsersAndOtherContentTypes() {
        var withOrigin = good
        withOrigin["origin"] = "https://example.com"
        #expect(!EventServer.accepts(request(headers: withOrigin), token: "abc123"))
        withOrigin["origin"] = "null"
        #expect(!EventServer.accepts(request(headers: withOrigin), token: "abc123"))
        for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"] {
            #expect(!EventServer.accepts(request(headers: ["content-type": type, "x-hook-token": "abc123"]), token: "abc123"))
        }
        #expect(!EventServer.accepts(request(headers: ["x-hook-token": "abc123"]), token: "abc123"))
    }

    @Test func rejectsOtherMethodsAndPaths() {
        #expect(!EventServer.accepts(request(method: "GET", headers: good), token: "abc123"))
        #expect(!EventServer.accepts(request(path: "/other", headers: good), token: "abc123"))
        #expect(!EventServer.accepts(request(path: "/claude-event/../x", headers: good), token: "abc123"))
    }

    @Test func sizeCaps() {
        let big = "POST /claude-event HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes + 1)\r\n\r\n"
        #expect(HTTPRequest.parse(Data(big.utf8)) == .tooLarge)
        let exact = "POST /claude-event HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes)\r\n\r\n"
        #expect(HTTPRequest.parse(Data(exact.utf8)) == .incomplete)
        let longHeader = "POST /claude-event HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: HTTPRequest.maxHeaderBytes)
        #expect(HTTPRequest.parse(Data(longHeader.utf8)) == .tooLarge)
        #expect(HTTPRequest.parse(Data((longHeader + "\r\n\r\n").utf8)) == .tooLarge)
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)) == .invalid)
    }

    @Test func parsesACompleteRequest() {
        let raw = "POST /claude-event HTTP/1.1\r\nContent-Type: application/json\r\nX-Hook-Token: t\r\nContent-Length: 2\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else {
            Issue.record("not parsed"); return
        }
        #expect(request.headers["x-hook-token"] == "t")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func emptyFieldsCountAsAbsent() {
        let compact = EventServer.compact(["a": "", "b": "x", "tool_input": ["file_path": "", "description": ""], "n": 3])
        #expect(compact["a"] == nil)
        #expect(compact["b"] as? String == "x")
        #expect(compact["tool_input"] == nil)
        #expect(compact["n"] as? Int == 3)
    }
}

@Suite("Unix socket server", .serialized)
struct SocketServerTests {

    /// Sends raw bytes to a Unix socket with plain POSIX calls (what curl does).
    nonisolated static func send(_ text: String, to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let data = Array(text.utf8)
        guard write(fd, data, data.count) == data.count else { return false }
        var buffer = [UInt8](repeating: 0, count: 256)
        _ = read(fd, &buffer, buffer.count)   // wait for the answer
        return true
    }

    nonisolated static func post(path: String = "/claude-event", body: String, token: String?, origin: String? = nil) -> String {
        var head = "POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
        if let token { head += "X-Hook-Token: \(token)\r\n" }
        if let origin { head += "Origin: \(origin)\r\n" }
        return head + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
    }

    @Test func socketIsPrivateAndOnlyTheTokenGetsThrough() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("s.sock").path

        let server = EventServer()
        server.tokenProvider = { "secret-token" }
        var received: [(String, [String: Any])] = []
        server.onRequest = { path, object in received.append((path, object)) }
        server.start(socketPath: socketPath)
        defer { server.stop() }

        #expect(await waitUntil { permissions(socketPath) == 0o600 })

        let body = #"{"event":"Stop","payload":{"session_id":"s1","cwd":""}}"#
        // Wrong token, no token, and a browser-style Origin are all dropped.
        for raw in [Self.post(body: body, token: "wrong"), Self.post(body: body, token: nil),
                    Self.post(body: body, token: "secret-token", origin: "https://example.com")] {
            let sent = await Task.detached { Self.send(raw, to: socketPath) }.value
            #expect(sent)
        }
        let good = Self.post(body: body, token: "secret-token")
        let sent = await Task.detached { Self.send(good, to: socketPath) }.value
        #expect(sent)

        #expect(await waitUntil { received.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(received.count == 1)
        #expect(received.first?.0 == "/claude-event")
        let payload = received.first?.1["payload"] as? [String: Any]
        #expect(payload?["session_id"] as? String == "s1")
        #expect(payload?["cwd"] == nil)   // empty fields are dropped
    }

    @Test func installedScriptsReachTheServer() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = ClaudeHooks.Paths(settings: dir.appendingPathComponent("settings.json"),
                                      script: dir.appendingPathComponent("hook.sh"),
                                      statusLine: dir.appendingPathComponent("status.sh"),
                                      token: dir.appendingPathComponent("token"),
                                      socket: dir.appendingPathComponent("s.sock").path)
        let token = try ClaudeHooks.install(paths)

        let server = EventServer()
        server.tokenProvider = { ClaudeHooks.currentToken(tokenURL: paths.token) }
        var received: [(String, [String: Any])] = []
        server.onRequest = { path, object in received.append((path, object)) }
        server.start(socketPath: paths.socket)
        defer { server.stop() }
        #expect(await waitUntil { FileManager.default.fileExists(atPath: paths.socket) })
        #expect(ClaudeHooks.currentToken(tokenURL: paths.token) == token)

        // A hook event with fields that must NOT be forwarded (the prompt, the full command,
        // tool output) next to the ones that should.
        let hookInput = #"""
        {"session_id":"abc","cwd":"/tmp/demo-app","transcript_path":"/tmp/x.jsonl","hook_event_name":"PreToolUse",
         "tool_name":"Bash","prompt":"my secret prompt","tool_response":"private output",
         "tool_input":{"command":"cd /x && git push --token=SECRET","description":"Push \"it\""}}
        """#
        try runScript(paths.script.path, argument: "PreToolUse", input: hookInput)

        let statusInput = #"""
        {"session_id":"abc","model":{"id":"claude-opus-5-5"},"workspace":{"current_dir":"/tmp/demo-app"},
         "cost":{"total_cost_usd":1.25},
         "rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":"2026-11-11T18:00:00Z"},"seven_day":{"used_percentage":12}},
         "context_window":{"used_percentage":31,"total_input_tokens":62000}}
        """#
        try runScript(paths.statusLine.path, argument: nil, input: statusInput)

        #expect(await waitUntil(seconds: 8) { received.count == 2 })
        let event = received.first { $0.0 == "/claude-event" }?.1
        #expect(event?["event"] as? String == "PreToolUse")
        let payload = event?["payload"] as? [String: Any]
        #expect(payload?["session_id"] as? String == "abc")
        #expect(payload?["tool_name"] as? String == "Bash")
        let input = payload?["tool_input"] as? [String: Any]
        #expect(input?["command"] as? String == "git")              // only the program name
        #expect(input?["description"] as? String == #"Push "it""#)
        #expect(payload?["prompt"] == nil)
        #expect(payload?["tool_response"] == nil)
        let flat = String(describing: event ?? [:])
        #expect(!flat.contains("SECRET") && !flat.contains("secret prompt") && !flat.contains("private output"))

        let limits = received.first { $0.0 == "/claude-limits" }?.1
        let rate = limits?["rate_limits"] as? [String: Any]
        #expect(((rate?["five_hour"] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue == 42.5)
        #expect(limits?["cost"] == nil && limits?["model"] == nil && limits?["workspace"] == nil)
        let parsed = ClaudeLimits.parse(limits ?? [:], source: .statusLine, now: Date())
        #expect(parsed?.fiveHour?.percent == 42.5)
        #expect(parsed?.fiveHour?.resetsAt == ISODate.parse("2026-11-11T18:00:00Z")?.timeIntervalSince1970)
        #expect(parsed?.sevenDay?.percent == 12)
        #expect(parsed?.sevenDay?.resetsAt == nil)
    }

    private func runScript(_ path: String, argument: String?, input: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = argument.map { [$0] } ?? []
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@Suite("Hook install on a temp settings file")
struct HookInstallTests {

    private func paths(in dir: URL) -> ClaudeHooks.Paths {
        ClaudeHooks.Paths(settings: dir.appendingPathComponent("claude/settings.json"),
                          script: dir.appendingPathComponent("support/hook.sh"),
                          statusLine: dir.appendingPathComponent("support/status.sh"),
                          token: dir.appendingPathComponent("support/token"),
                          socket: dir.appendingPathComponent("s.sock").path)
    }

    @Test func installKeepsOtherSettingsAndWritesABackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = paths(in: dir)
        try FileManager.default.createDirectory(at: p.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try Data(original.utf8).write(to: p.settings)

        try ClaudeHooks.install(p)

        // The backup is the file as it was.
        let backup = try String(contentsOf: ClaudeHooks.backupURL(for: p.settings), encoding: .utf8)
        #expect(backup == original)

        let settings = try ClaudeHooks.readSettings(p.settings)
        #expect(settings["model"] as? String == "opus")
        let stop = (settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)    // theirs and ours
        #expect(ClaudeHooks.isInstalled(in: settings, scriptPath: p.script.path))
        #expect(ClaudeHooks.ownsStatusLine(settings, statusLinePath: p.statusLine.path))
        let pre = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.first?["matcher"] as? String == "*")

        // Secrets and scripts are private.
        #expect(permissions(p.token.path) == 0o600)
        #expect(permissions(p.script.path) == 0o700)
        #expect(permissions(p.statusLine.path) == 0o700)
        #expect(permissions(p.script.deletingLastPathComponent().path) == 0o700)
        let token = try String(contentsOf: p.token, encoding: .utf8)
        #expect(token.count == 64)
        let script = try String(contentsOf: p.script, encoding: .utf8)
        #expect(script.contains("--unix-socket"))
        #expect(!script.contains("127.0.0.1") && !script.contains("http://localhost:"))

        let state = ClaudeHooks.state(p)
        #expect(state == ClaudeHooks.InstallState(hooks: true, statusLine: true, foreignStatusLine: false))

        // Installing twice doesn't add twice.
        try ClaudeHooks.install(p)
        let again = try ClaudeHooks.readSettings(p.settings)
        #expect(((again["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count == 2)
        // The backup still holds the original, not our first edit.
        #expect(try String(contentsOf: ClaudeHooks.backupURL(for: p.settings), encoding: .utf8) == original)
    }

    @Test func aStatusLineOfYourOwnIsLeftAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = paths(in: dir)
        try FileManager.default.createDirectory(at: p.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"~/my-line.sh"}}"#.utf8).write(to: p.settings)

        try ClaudeHooks.install(p)
        let settings = try ClaudeHooks.readSettings(p.settings)
        #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == "~/my-line.sh")
        #expect(ClaudeHooks.state(p).foreignStatusLine)

        try ClaudeHooks.uninstall(p)
        let after = try ClaudeHooks.readSettings(p.settings)
        #expect((after["statusLine"] as? [String: Any])?["command"] as? String == "~/my-line.sh")
        #expect(after["hooks"] == nil)
    }

    @Test func uninstallRemovesOnlyOurs() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = paths(in: dir)
        try FileManager.default.createDirectory(at: p.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8).write(to: p.settings)
        try ClaudeHooks.install(p)
        try ClaudeHooks.uninstall(p)

        let settings = try ClaudeHooks.readSettings(p.settings)
        let hooks = settings["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["Stop"])
        #expect(((hooks?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
        #expect(settings["statusLine"] == nil)
        #expect(!FileManager.default.fileExists(atPath: p.token.path))
        #expect(!FileManager.default.fileExists(atPath: p.script.path))
        #expect(ClaudeHooks.currentToken(tokenURL: p.token) == nil)
    }

    @Test func unreadableSettingsAreNotTouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = paths(in: dir)
        try FileManager.default.createDirectory(at: p.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: p.settings)
        #expect(throws: ClaudeHooks.HookError.self) { try ClaudeHooks.install(p) }
        #expect(try String(contentsOf: p.settings, encoding: .utf8) == "{ not json")
    }

    @Test func tokensAreRandom() {
        let a = ClaudeHooks.makeToken(), b = ClaudeHooks.makeToken()
        #expect(a.count == 64 && b.count == 64 && a != b)
    }
}

@Suite("Transcript path validation")
struct TranscriptPathTests {

    @Test func onlyRegularFilesInsideTheProjectsFolder() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("projects")
        let project = root.appendingPathComponent("demo-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let inside = project.appendingPathComponent("s.jsonl")
        try Data("{}\n".utf8).write(to: inside)
        let outside = base.appendingPathComponent("elsewhere.jsonl")
        try Data("{}\n".utf8).write(to: outside)

        #expect(TranscriptReader.validated(inside.path, root: root.path) != nil)
        #expect(TranscriptReader.validated(outside.path, root: root.path) == nil)
        #expect(TranscriptReader.validated(project.path + "/../../elsewhere.jsonl", root: root.path) == nil)
        #expect(TranscriptReader.validated("relative/s.jsonl", root: root.path) == nil)
        #expect(TranscriptReader.validated(project.path, root: root.path) == nil)   // a folder

        // A symlink pointing out is refused; a FIFO inside is refused.
        let link = project.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(TranscriptReader.validated(link.path, root: root.path) == nil)
        let fifo = project.appendingPathComponent("pipe.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(TranscriptReader.validated(fifo.path, root: root.path) == nil)
    }
}
