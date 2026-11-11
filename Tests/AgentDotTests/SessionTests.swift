import Foundation
import Testing
@testable import AgentDot

@Suite("Live sessions from hook events")
struct SessionTests {

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func payload(_ id: String = "s1", cwd: String = "/Users/demo/code/alpha-app", extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = ["session_id": id, "cwd": cwd, "transcript_path": "/tmp/\(id).jsonl"]
        base.merge(extra) { $1 }
        return base
    }

    @Test func eventsDriveTheState() {
        let status = ClaudeStatus()
        status.handle(event: "SessionStart", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.state == .idle)
        #expect(status.sessionInfos.first?.project == "alpha-app")

        status.handle(event: "UserPromptSubmit", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.state == .working)
        #expect(status.sessionInfos.first?.activity == "thinking")

        status.handle(event: "PreToolUse", payload: payload(extra: ["tool_name": "Edit", "tool_input": ["file_path": "/a/b/PanelView.swift"]]), now: t0)
        #expect(status.sessionInfos.first?.activity == "editing PanelView.swift")

        status.handle(event: "PreToolUse", payload: payload(extra: ["tool_name": "Agent"]), now: t0)
        #expect(status.sessionInfos.first?.activity == "1 task running")
        status.handle(event: "SubagentStop", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.activity == "subtask done · continuing")

        status.handle(event: "Notification", payload: payload(extra: ["notification_type": "permission_prompt",
                                                               "message": "Claude needs your permission to use Bash"]), now: t0)
        #expect(status.sessionInfos.first?.state == .waiting)
        #expect(status.sessionInfos.first?.activity == "Claude needs your permission to use Bash")

        status.handle(event: "Stop", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.state == .done)

        status.handle(event: "SessionEnd", payload: payload(), now: t0)
        #expect(status.sessionInfos.isEmpty)
    }

    @Test func idlePromptIsNotNeedsYou() {
        let status = ClaudeStatus()
        status.handle(event: "Stop", payload: payload(), now: t0)
        status.handle(event: "Notification", payload: payload(extra: ["notification_type": "idle_prompt",
                                                               "message": "Claude is waiting for your input"]), now: t0)
        #expect(status.sessionInfos.first?.state == .done)
        status.handle(event: "Notification", payload: payload(extra: ["message": "Claude is waiting for your input"]), now: t0)
        #expect(status.sessionInfos.first?.state == .done)
    }

    @Test func failuresAndCommandsInPlainWords() {
        let status = ClaudeStatus()
        status.handle(event: "StopFailure", payload: payload(extra: ["error": "rate_limit"]), now: t0)
        #expect(status.sessionInfos.first?.state == .error)
        #expect(status.sessionInfos.first?.activity == "limit reached")
        #expect(ToolText.describe(tool: "Bash", input: ["command": "cd /x && git status"]) == "using git")
        #expect(ToolText.describe(tool: "Bash", input: ["description": "Build /Users/demo/a/App.xcodeproj"]) == "Build App.xcodeproj")
        #expect(ToolText.describe(tool: "WebFetch", input: ["url": "https://example.com/a?b"]) == "fetching example.com")
        #expect(ToolText.describe(tool: "mcp__Some_Browser__click", input: nil) == "using the browser")
        #expect(ToolText.prettyModel("claude-opus-5-5") == "Opus 5.5")
        #expect(ToolText.prettyModel("claude-haiku-4-5-20251001") == "Haiku 4.5")
    }

    @Test func settlesStaleSessions() {
        let status = ClaudeStatus()
        status.handle(event: "Stop", payload: payload("a"), now: t0)
        status.handle(event: "UserPromptSubmit", payload: payload("b", cwd: "/x/beta"), now: t0)
        // Done → idle after 90 s; transcripts "exist".
        #expect(status.refresh(now: t0.addingTimeInterval(100), fileExists: { _ in true }))
        #expect(status.sessionInfos.map(\.state) == [.working, .idle])
        // The reported transcripts were never validated here, so after 2 minutes they count as gone.
        #expect(status.refresh(now: t0.addingTimeInterval(130), fileExists: { _ in true }))
        #expect(status.sessionInfos.isEmpty)
    }

    @Test func statusLineContextBeatsTheEstimate() {
        let status = ClaudeStatus()
        // The statusLine can arrive before the first hook.
        #expect(!status.updateContext(sessionID: "s1", percent: 37))
        status.handle(event: "SessionStart", payload: payload(), now: t0)
        #expect(status.sessionInfos.first?.contextPercent == 37)
        #expect(status.updateContext(sessionID: "s1", percent: 40))
        #expect(!status.updateContext(sessionID: "s1", percent: 40))
        #expect(status.sessionInfos.first?.contextPercent == 40)
    }

    @Test func transcriptGivesModelContextAndEnd() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("projects")
        let file = root.appendingPathComponent("-Users-demo-code-alpha/s1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let answer = #"{"type":"assistant","message":{"model":"claude-opus-5-5","stop_reason":"end_turn","usage":{"input_tokens":1000,"cache_read_input_tokens":99000,"cache_creation_input_tokens":20000,"output_tokens":5}}}"#
        try Data(("{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n" + answer + "\n").utf8).write(to: file)

        let status = ClaudeStatus()
        status.handle(event: "UserPromptSubmit", payload: payload(extra: ["transcript_path": file.path]), now: t0)
        let reads = status.transcriptReads(now: t0.addingTimeInterval(30))
        #expect(reads.count == 1 && reads[0].wantsUsage && reads[0].wantsEnd)
        let result = TranscriptReader.read(reads[0], root: root.path)
        #expect(result.validPath != nil)
        #expect(result.usage == TranscriptReader.Usage(model: "claude-opus-5-5", contextTokens: 120_000))
        #expect(result.end == .finished)
        #expect(status.apply(reads[0], result: result, now: t0.addingTimeInterval(30)))
        let info = status.sessionInfos.first
        #expect(info?.state == .done)
        #expect(info?.model == "claude-opus-5-5")
        #expect(info?.contextPercent == 12)      // 120k of a 1M window
        #expect(status.transcripts.first?.path == result.validPath)

        // Interrupted by Esc.
        let lines: [Substring] = [#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#]
        #expect(TranscriptReader.turnEnd(lines: lines) == .interrupted)
        #expect(TranscriptReader.turnEnd(lines: [#"{"type":"user","message":{"content":"tool result"}}"#]) == .running)
    }

    @Test func overallDotAndBanners() {
        func info(_ id: String, _ state: ClaudeStatus.State) -> ClaudeSessionInfo {
            ClaudeSessionInfo(id: id, project: id, state: state, activity: "", model: nil, contextPercent: nil,
                              cwd: nil, stateSince: t0)
        }
        #expect(OverallState.from([]) == .idle)
        #expect(OverallState.from([info("a", .done), info("b", .idle)]) == .idle)
        #expect(OverallState.from([info("a", .working), info("b", .done)]) == .working)
        #expect(OverallState.from([info("a", .working), info("b", .waiting)]) == .needsYou)

        let before = [info("a", .waiting), info("b", .working)]
        let after = [info("a", .waiting), info("b", .waiting), info("c", .working)]
        #expect(NeedsYouNotifier.newlyWaiting(old: before, new: after).map(\.id) == ["b"])
        #expect(NeedsYouNotifier.newlyWaiting(old: after, new: after).isEmpty)
    }
}

@Suite("Background tasks (subagents)")
struct SubagentTests {

    @Test func readsAgentsNextToTheTranscript() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("projects")
        let transcript = root.appendingPathComponent("-Users-demo-code-alpha/s1.jsonl")
        let agents = transcript.deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)
        try Data(#"{"description":"Review the parser","agentType":"general-purpose"}"#.utf8)
            .write(to: agents.appendingPathComponent("agent-a1.meta.json"))
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90))
        let running = [
            #"{"type":"user","timestamp":"\#(stamp)","message":{"content":"go"}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/Parser.swift"}}]}}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"cd /x && swift test"}}]}}"#,
        ]
        let agentFile = agents.appendingPathComponent("agent-a1.jsonl")
        try Data((running.joined(separator: "\n") + "\n").utf8).write(to: agentFile)
        // A finished agent is not listed.
        try Data(#"{"type":"assistant","message":{"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#.appending("\n").utf8)
            .write(to: agents.appendingPathComponent("agent-a2.jsonl"))

        let scanner = SubagentScanner(root: root.path)
        let found = scanner.scan(sessions: [(sessionID: "s1", project: "alpha", path: transcript.path)])
        #expect(found.count == 1)
        let agent = found.first
        #expect(agent?.name == "Review the parser")
        #expect(agent?.toolUses == 2)
        #expect(agent?.current == "Building the app")
        #expect(agent?.model == "Sonnet 5.5")
        #expect(agent?.project == "alpha")
        #expect(abs((agent?.startedAt.timeIntervalSinceNow ?? 0) + 90) < 2)

        // It reads on from where it stopped; the hand-back ends it.
        let handle = try FileHandle(forWritingTo: agentFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"SubagentHandback","input":{}}]}}"# + "\n").utf8))
        try handle.close()
        #expect(scanner.scan(sessions: [(sessionID: "s1", project: "alpha", path: transcript.path)]).isEmpty)
    }

    @Test func agentFilesOutsideTheRootAreIgnored() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = base.appendingPathComponent("elsewhere/s1.jsonl")
        let agents = elsewhere.deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}"#.appending("\n").utf8)
            .write(to: agents.appendingPathComponent("agent-x.jsonl"))
        let scanner = SubagentScanner(root: root.path)
        #expect(scanner.scan(sessions: [(sessionID: "s1", project: "p", path: elsewhere.path)]).isEmpty)
    }
}
