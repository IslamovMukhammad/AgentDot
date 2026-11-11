import Foundation
import Testing
@testable import AgentDot

/// One assistant line as Claude Code writes it.
func assistantLine(id: String?, model: String = "claude-opus-5-5", at date: Date, input: Int = 0, output: Int = 0,
                   cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0, legacyCreation: Int? = nil,
                   cwd: String = "/Users/demo/Desktop/alpha-app") -> String {
    var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": cacheRead]
    if let legacyCreation {
        usage["cache_creation_input_tokens"] = legacyCreation
    } else {
        usage["cache_creation_input_tokens"] = write5m + write1h
        usage["cache_creation"] = ["ephemeral_5m_input_tokens": write5m, "ephemeral_1h_input_tokens": write1h]
    }
    var message: [String: Any] = ["model": model, "usage": usage, "role": "assistant", "content": []]
    if let id { message["id"] = id }
    let object: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date),
                                 "cwd": cwd, "message": message, "uuid": UUID().uuidString]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    // Claude Code writes compact JSON without spaces: `"type":"assistant"` is what the quick filter looks for.
    return String(decoding: data, as: UTF8.self)
}

@Suite("Usage by project: jsonl parsing, dedupe, cost")
struct ProjectUsageTests {

    let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!

    private func makeRoot() throws -> URL {
        let root = try makeTempDir("cmu").appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ lines: [String], to url: URL, trailingNewline: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func dedupesByMessageIDAcrossFilesIncludingSubagents() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let dir = root.appendingPathComponent("-Users-demo-Desktop-alpha-app")
        // The same answer written twice (streamed blocks): the copy with more output wins.
        try write([
            assistantLine(id: "msg_1", at: now, input: 100, output: 10),
            assistantLine(id: "msg_1", at: now, input: 100, output: 50),
            assistantLine(id: "msg_2", at: now, input: 200, output: 20),
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        ], to: dir.appendingPathComponent("s1.jsonl"))
        // A resumed session copies msg_2 into a new file; a subagent adds msg_3.
        try write([assistantLine(id: "msg_2", at: now, input: 200, output: 20)],
                  to: dir.appendingPathComponent("s2.jsonl"))
        try write([assistantLine(id: "msg_3", model: "claude-sonnet-5-5", at: now, input: 1000, output: 100)],
                  to: dir.appendingPathComponent("s1/subagents/agent-a1.jsonl"))

        var state = ProjectUsageState()
        #expect(ProjectUsageScan.run(&state, root: root, now: now))
        #expect(state.records.count == 3)
        #expect(state.records["msg_1"]?[4] == 50)

        let summary = ProjectUsageScan.summary(from: state, now: now)
        #expect(summary.today.rows.map(\.project) == ["alpha-app"])
        let expectedTokens: Int = 150 + 220 + 1100
        #expect(summary.today.tokens == expectedTokens)
        // Opus 5.5: $4 in / $20 out per million; Sonnet 5.5: $2 / $10.
        let opus: Double = (300.0 * 4 + 70.0 * 20) / 1_000_000
        let sonnet: Double = (1000.0 * 2 + 100.0 * 10) / 1_000_000
        let expected = opus + sonnet
        #expect(abs(summary.today.cost - expected) < 1e-12)
        #expect(!summary.unpriced)

        // Nothing new: a second scan changes nothing.
        #expect(!ProjectUsageScan.run(&state, root: root, now: now))
    }

    @Test func readsOnlyNewLinesAndWaitsForHalfLines() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("-Users-demo-Desktop-beta/s.jsonl")
        try write([assistantLine(id: "m1", at: now, input: 10, output: 1)], to: file)

        var state = ProjectUsageState()
        _ = ProjectUsageScan.run(&state, root: root, now: now)
        let firstOffset = state.files[file.path]?.first
        #expect(state.records.count == 1)

        // Half a line (still being written) isn't taken yet.
        let next = assistantLine(id: "m2", at: now, input: 20, output: 2)
        let half = next.prefix(next.count / 2)
        try append(String(half), to: file)
        _ = ProjectUsageScan.run(&state, root: root, now: now)
        #expect(state.records.count == 1)
        #expect(state.files[file.path]?.first == firstOffset)

        try append(String(next.dropFirst(half.count)) + "\n", to: file)
        #expect(ProjectUsageScan.run(&state, root: root, now: now))
        #expect(state.records.count == 2)
        #expect(state.records["m2"]?[3] == 20)
    }

    @Test func costUsesCacheRatesAndLegacyFormat() {
        // Opus 5.5: cache read $0.20, 5-minute write $5, 1-hour write $8 per million.
        let cost = ClaudePricing.cost(model: "claude-opus-5-5", input: 1_000_000, output: 1_000_000,
                                      cacheRead: 1_000_000, write5m: 1_000_000, write1h: 1_000_000)
        let full: Double = 37.2   // 4 + 20 + 0.20 + 5 + 8
        #expect(abs((cost ?? 0) - full) < 1e-9)
        // Haiku 5.5 has a higher rate above 100k prompt tokens.
        #expect(ClaudePricing.price(model: "claude-haiku-5-5", promptTokens: 50_000)?.input == 0.1)
        #expect(ClaudePricing.price(model: "claude-haiku-5-5", promptTokens: 150_000)?.input == 0.5)
        #expect(ClaudePricing.price(model: "gpt-something", promptTokens: 0) == nil)

        // Older lines have only cache_creation_input_tokens: counted as 5-minute writes.
        var state = ProjectUsageState()
        let line = assistantLine(id: "x", at: now, legacyCreation: 1_000_000)
        #expect(ProjectUsageScan.parse(line: Data(line.utf8), dir: "-Users-demo-Desktop-x", state: &state, now: now))
        #expect(state.records["x"]?[6] == 1_000_000)
        #expect(state.records["x"]?[7] == 0)
    }

    @Test func unknownModelsAreMarkedAndSyntheticOnesSkipped() throws {
        var state = ProjectUsageState()
        let unknown = assistantLine(id: "u", model: "claude-future-9", at: now, input: 10, output: 10)
        #expect(ProjectUsageScan.parse(line: Data(unknown.utf8), dir: "d", state: &state, now: now))
        let synthetic = assistantLine(id: "s", model: "<synthetic>", at: now, input: 10, output: 10)
        #expect(!ProjectUsageScan.parse(line: Data(synthetic.utf8), dir: "d", state: &state, now: now))
        let summary = ProjectUsageScan.summary(from: state, now: now)
        #expect(summary.unpriced)
        #expect(summary.today.cost == 0)
        #expect(summary.today.tokens == 20)
    }

    @Test func periodsAndOldRecords() {
        var state = ProjectUsageState()
        let day: TimeInterval = 86_400
        for (id, ago) in [("today", 0.0), ("week", 3 * day), ("month", 20 * day), ("old", 40 * day)] {
            let line = assistantLine(id: id, at: now.addingTimeInterval(-ago), input: 1000, output: 0)
            _ = ProjectUsageScan.parse(line: Data(line.utf8), dir: "-Users-demo-Desktop-p", state: &state, now: now)
        }
        #expect(state.records["old"] == nil)       // past the 35 days kept
        let summary = ProjectUsageScan.summary(from: state, now: now)
        #expect(summary.today.tokens == 1000)
        #expect(summary.week.tokens == 2000)
        #expect(summary.month.tokens == 3000)
    }

    @Test func projectNames() {
        #expect(ProjectUsageScan.projectName(dir: "-Users-demo-Desktop-alpha-app", cwd: nil) == "alpha-app")
        #expect(ProjectUsageScan.projectName(dir: "-Users-demo-Desktop-alpha-app--claude-worktrees-fix", cwd: nil) == "alpha-app")
        #expect(ProjectUsageScan.projectName(dir: "-Users-demo-notes", cwd: nil) == "notes")
        #expect(ProjectUsageScan.projectName(dir: "-Users-demo", cwd: nil) == "home")
        #expect(ProjectUsageScan.projectName(dir: "-private-tmp-xyz", cwd: nil) == "tmp")
        #expect(ProjectUsageScan.projectName(dir: "weird", cwd: "/a/b/gamma") == "gamma")
    }

    @Test func symlinkedTranscriptsAreSkipped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.jsonl")
        try write([assistantLine(id: "o", at: now, input: 5, output: 5)], to: outside)
        let dir = root.appendingPathComponent("-Users-demo-Desktop-c")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("l.jsonl"), withDestinationURL: outside)
        var state = ProjectUsageState()
        _ = ProjectUsageScan.run(&state, root: root, now: now)
        #expect(state.records.isEmpty)
    }

    @Test func mainActorWrapperPublishes() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try write([assistantLine(id: "w", at: Date(), input: 10, output: 10)],
                  to: root.appendingPathComponent("-Users-demo-Desktop-delta/s.jsonl"))
        let usage = ProjectUsage(root: root, fileURL: nil)
        var published: ProjectUsageSummary?
        usage.onChange = { published = $0 }
        await usage.scan()
        #expect(published?.today.rows.first?.project == "delta")
        #expect(usage.latest?.today.tokens == 20)
    }

    @Test func formatting() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(12_400) == "12k")
        #expect(Format.tokens(2_480_000) == "2.5M")
        #expect(Format.cost(3.456) == "$3.46")
        #expect(Format.cost(164.8) == "$165")
        #expect(Format.elapsed(134) == "2:14")
        #expect(Format.elapsed(3725) == "1:02:05")
        let base = Date(timeIntervalSince1970: 1_000_000)
        #expect(Format.resets(base.addingTimeInterval(2 * 3600 + 14 * 60), now: base) == "Resets in 2h 14m")
        #expect(Format.resets(base.addingTimeInterval(9 * 60), now: base) == "Resets in 9m")
    }
}
