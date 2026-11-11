import Foundation

/// One background agent (a subagent a session started): what the "Background tasks" section shows.
nonisolated struct SubagentInfo: Equatable, Identifiable, Sendable {
    let id: String
    /// Its description, e.g. "Review the parser".
    let name: String
    let kind: String
    let model: String
    let startedAt: Date
    let toolUses: Int
    /// The current action in plain words, e.g. "Running the tests".
    let current: String
    let project: String
    let sessionID: String
}

/// Watches the subagents of the sessions we know about. For each agent Claude Code writes, next
/// to the session transcript (`<session>.jsonl`):
///
///     <session>/subagents/agent-<id>.meta.json   its description and type
///     <session>/subagents/agent-<id>.jsonl       its live transcript
///
/// Only folders next to already validated transcripts are looked at, each agent file is checked
/// to be a regular file inside `~/.claude/projects`, and a transcript is read on from where the
/// last read stopped (the offset is kept). Used from one background queue only.
nonisolated final class SubagentScanner: @unchecked Sendable {

    /// An agent file that hasn't changed for this long, without an end marker, has stopped
    /// (a long build can be quiet for minutes, so this is long).
    static let staleAfter: TimeInterval = 10 * 60
    /// At most this much new transcript is read per agent per pass.
    private static let maxRead = 4 * 1024 * 1024

    private final class Track {
        var offset: UInt64 = 0
        var toolUses = 0
        var current = "starting"
        var startedAt: Date?
        var model = ""
        var finished = false
        var meta: (name: String, kind: String)?
    }

    private var tracks: [String: Track] = [:]
    private let root: String

    init(root: String = TranscriptReader.projectsRoot) {
        self.root = root
    }

    func scan(sessions: [(sessionID: String, project: String, path: String)], now: Date = Date()) -> [SubagentInfo] {
        let fm = FileManager.default
        var agents: [SubagentInfo] = []
        var seen = Set<String>()

        for session in sessions where session.path.hasSuffix(".jsonl") {
            let dir = String(session.path.dropLast(".jsonl".count)) + "/subagents"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in names where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
                guard let path = TranscriptReader.validated(dir + "/" + file, root: root),
                      let attrs = try? fm.attributesOfItem(atPath: path),
                      let modified = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) < Self.staleAfter else { continue }

                let id = String(file.dropLast(".jsonl".count))
                let key = session.sessionID + "/" + id
                seen.insert(key)
                let track = tracks[key] ?? Track()
                tracks[key] = track
                if track.meta == nil {
                    track.meta = TranscriptReader.validated(dir + "/" + id + ".meta.json", root: root).flatMap(Self.readMeta)
                }
                read(path, into: track, size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0)
                if track.finished { continue }

                agents.append(SubagentInfo(
                    id: key,
                    name: track.meta?.name ?? "Agent",
                    kind: track.meta?.kind ?? "agent",
                    model: ToolText.prettyModel(track.model),
                    startedAt: track.startedAt ?? modified,
                    toolUses: track.toolUses,
                    current: track.current,
                    project: session.project,
                    sessionID: session.sessionID))
            }
        }
        tracks = tracks.filter { seen.contains($0.key) }
        return agents.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Files

    private static func readMeta(_ path: String) -> (name: String, kind: String)? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (object["description"] as? String) ?? (object["agentType"] as? String) ?? "Agent"
        return (ToolText.shorten(name, limit: 60), (object["agentType"] as? String) ?? "agent")
    }

    /// Reads on from the last offset; only whole (newline-ended) lines are taken, a half-written
    /// line waits for the next pass.
    private func read(_ path: String, into track: Track, size: UInt64) {
        if size < track.offset { track.offset = 0 }       // the file was replaced
        guard size > track.offset else { return }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: track.offset)
            let count = Int(min(size - track.offset, UInt64(Self.maxRead)))
            guard let data = try handle.read(upToCount: count), let lastNewline = data.lastIndex(of: 0x0A) else {
                // One line bigger than the read window (a pasted image, say): skip past it.
                if size - track.offset >= UInt64(Self.maxRead) { track.offset += UInt64(Self.maxRead) }
                return
            }
            track.offset += UInt64(lastNewline - data.startIndex + 1)
            for line in data[..<lastNewline].split(separator: 0x0A) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                Self.parse(object, into: track)
            }
        } catch {}
    }

    private static func parse(_ entry: [String: Any], into track: Track) {
        if track.startedAt == nil, let stamp = entry["timestamp"] as? String {
            track.startedAt = ISODate.parse(stamp)
        }
        guard let message = entry["message"] as? [String: Any] else { return }
        if let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<") { track.model = model }
        guard (entry["type"] as? String) == "assistant" else { return }
        let stop = message["stop_reason"] as? String
        var usedTool = false
        var handedBack = false
        for block in (message["content"] as? [[String: Any]]) ?? [] where (block["type"] as? String) == "tool_use" {
            // The agent hands its work back with this call; its transcript ends after it.
            if (block["name"] as? String) == "SubagentHandback" {
                handedBack = true
                continue
            }
            usedTool = true
            track.toolUses += 1
            track.current = short(ToolText.describe(tool: block["name"] as? String ?? "tool",
                                                    input: block["input"] as? [String: Any]))
        }
        // The last answer has no tool call and ended its turn: the agent is done.
        if handedBack || (stop == "end_turn" && !usedTool) {
            track.finished = true
            track.current = "done"
        }
    }

    /// A short line, not a long command or path: "cd … &&" is dropped, capitalized, 52 characters.
    private static func short(_ text: String) -> String {
        var t = text
        if let range = t.range(of: #"^[Cc]d\s+\S+\s*&&\s*"#, options: .regularExpression) { t.removeSubrange(range) }
        t = t.replacingOccurrences(of: "\n", with: " ")
        t = t.prefix(1).uppercased() + t.dropFirst()
        return t.count > 52 ? String(t.prefix(51)) + "…" : t
    }
}

/// ISO-8601 dates as Claude Code writes them, with or without fractional seconds.
nonisolated enum ISODate {
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// An epoch number (seconds), a numeric string, or an ISO-8601 string.
    static func epoch(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let number = Double(text), number.isFinite { return number }
        return parse(text)?.timeIntervalSince1970
    }
}
