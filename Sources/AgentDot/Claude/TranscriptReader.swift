import Foundation

/// Reads the end of a session transcript (a `.jsonl` file Claude Code writes). Never called on
/// the main thread.
nonisolated enum TranscriptReader {

    enum TurnEnd: Sendable { case finished, interrupted, running }

    struct Usage: Equatable, Sendable {
        /// e.g. "claude-opus-5-5"
        let model: String
        /// Everything that filled the context: new input + cache read + cache write.
        let contextTokens: Int
    }

    struct Result: Sendable {
        var validPath: String?
        var size: UInt64 = 0
        var usage: Usage?
        var end: TurnEnd?
    }

    static var projectsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    }

    /// The path the hook reported, or nil unless it resolves (symlinks and "..") to a regular
    /// file inside Claude's projects folder. A FIFO or a device would block the reader, and
    /// anything outside that folder is none of this app's business.
    static func validated(_ path: String, root: String = projectsRoot) -> String? {
        guard path.hasPrefix("/"), let real = realPath(path), let realRoot = realPath(root) else { return nil }
        guard real.hasPrefix(realRoot.hasSuffix("/") ? realRoot : realRoot + "/") else { return nil }
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return real
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Reads a reported transcript. Model and context are parsed only when the file changed size.
    static func read(_ read: ClaudeStatus.TranscriptRead, root: String = projectsRoot) -> Result {
        guard let valid = validated(read.path, root: root) else { return Result() }
        var result = Result(validPath: valid)
        let size = (try? FileManager.default.attributesOfItem(atPath: valid)[.size] as? NSNumber)?.uint64Value ?? 0
        result.size = size
        let needsUsage = read.wantsUsage && size != read.knownSize
        guard needsUsage || read.wantsEnd else { return result }
        let lines = tailLines(valid)
        if needsUsage { result.usage = usage(lines: lines) }
        if read.wantsEnd { result.end = turnEnd(lines: lines) }
        return result
    }

    /// Opened non-blocking and re-checked as a regular file on the open descriptor, so a file
    /// swapped after validation still can't hang the read. The last 512 KB is plenty: only the
    /// most recent entries matter.
    static func tailLines(_ path: String, window: UInt64 = 512 * 1024) -> [Substring] {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        // A cut first line is just not valid JSON and gets skipped.
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    /// Did the last answer end? A final assistant entry with `end_turn` means yes; a later
    /// "user" entry (a tool result or a new prompt) means it is still going.
    static func turnEnd(lines: [Substring]) -> TurnEnd {
        for line in lines.reversed() {
            guard let object = json(line), let type = object["type"] as? String else { continue }
            if type == "user" {
                // Esc may not send the Stop hook; the transcript gets "[Request interrupted by user…]".
                return isInterruptMarker(object) ? .interrupted : .running
            }
            if type == "assistant", let reason = (object["message"] as? [String: Any])?["stop_reason"] as? String {
                return ["end_turn", "stop_sequence", "max_tokens"].contains(reason) ? .finished : .running
            }
        }
        return .running
    }

    /// Model and context size of the latest assistant answer.
    static func usage(lines: [Substring]) -> Usage? {
        for line in lines.reversed() where line.contains("\"usage\"") {
            guard let object = json(line), object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String, model.hasPrefix("claude"),
                  let usage = message["usage"] as? [String: Any] else { continue }
            func number(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let tokens = number("input_tokens") + number("cache_read_input_tokens") + number("cache_creation_input_tokens")
            return Usage(model: model, contextTokens: tokens)
        }
        return nil
    }

    /// The model's context window, only a fallback when the statusLine hasn't sent Claude Code's
    /// own percentage.
    static func contextWindow(for model: String) -> Int {
        let id = model.lowercased()
        if id.contains("haiku-4") || id.contains("sonnet-4") || id.contains("opus-4") { return 200_000 }
        return 1_000_000
    }

    static func json(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func isInterruptMarker(_ object: [String: Any]) -> Bool {
        guard let message = object["message"] as? [String: Any] else { return false }
        let marker = "[Request interrupted by user"
        if let text = message["content"] as? String { return text.hasPrefix(marker) }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.contains { ($0["text"] as? String)?.hasPrefix(marker) == true }
        }
        return false
    }
}
