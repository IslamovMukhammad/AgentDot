import Foundation
import Security

/// Installs (or removes) the Claude Code hooks that feed the panel. Nothing here runs until you
/// click "Install hooks" in Settings.
///
/// The pieces, all in Application Support/AgentDot (0700) plus Claude's settings:
///   1. `agentdot-hook.sh` (0700): reads a hook's JSON from stdin, keeps only the few fields the
///      panel needs, and posts them to the app's Unix socket in the background. It never blocks
///      Claude and always exits 0. Your prompts and tool output never leave Claude.
///   2. `agentdot-statusline.sh` (0700): the same for Claude Code's statusLine update, which is
///      the only place the 5-hour and 7-day plan limits appear. Sends the limits, the session id
///      and the context fill, nothing else. Installed only when you have no statusLine of your own.
///   3. `hook-token` (0600): a random token made at install. The scripts send it with every
///      request and the app drops anything without it.
///   4. One entry per hook event in `~/.claude/settings.json` (plus `statusLine` if it was empty).
///      Other hooks in that file are left alone, and a backup is written before the first change.
enum ClaudeHooks {

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "SubagentStop", "Notification", "Stop", "StopFailure", "SessionEnd"]
    /// Tool events need a matcher; "*" means every tool.
    private static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var scriptURL: URL { AppSupport.directory.appendingPathComponent("agentdot-hook.sh") }
    static var statusLineURL: URL { AppSupport.directory.appendingPathComponent("agentdot-statusline.sh") }
    static var tokenURL: URL { AppSupport.directory.appendingPathComponent("hook-token") }

    /// 32 random bytes as hex.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static var cachedToken: String??

    /// The installed token, or nil when the hooks aren't installed (then every request is dropped).
    static func currentToken(tokenURL: URL = tokenURL) -> String? {
        if tokenURL == Self.tokenURL, let cached = cachedToken { return cached }
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (token?.isEmpty ?? true) ? nil : token
        if tokenURL == Self.tokenURL { cachedToken = .some(value) }
        return value
    }

    /// Wrapped in single quotes for sh; a single quote inside becomes '\''.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func hookScript(socketPath: String, token: String) -> String {
        fill(hookTemplate, socketPath: socketPath, token: token)
    }

    static func statusLineScript(socketPath: String, token: String) -> String {
        fill(statusLineTemplate, socketPath: socketPath, token: token)
    }

    private static func fill(_ template: String, socketPath: String, token: String) -> String {
        template
            .replacingOccurrences(of: "__SOCKET__", with: shellQuoted(socketPath))
            .replacingOccurrences(of: "__TOKEN__", with: shellQuoted(token))
    }

    /// Shared by both scripts: read one field of the JSON on stdin, and escape text for JSON.
    private static let helpers = #"""
      field() { printf '%s' "$PAYLOAD" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
      # JSON string: drop control characters, escape backslashes and quotes.
      esc() { printf '%s' "$1" | /usr/bin/tr -d '\000-\037' | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
      # JSON number, or null when the field is missing or isn't a plain number.
      num() { v=$(field "$1"); case "$v" in ''|*[!0-9.eE+-]*) printf 'null' ;; *) printf '%s' "$v" ;; esac; }
    """#

    private static let hookTemplate = #"""
    #!/bin/sh
    # Installed by AgentDot. Sends a few fields of each Claude Code hook event to the
    # menu-bar app over its own Unix socket. Never blocks Claude and never returns an error.
    #
    # Only these leave Claude: the event name, session id, working folder, transcript path,
    # tool name, a short hint about the tool (its description, a file name, a web host, a
    # search query, a skill, or just the program name of a shell command) and the text of
    # a notification. Never your prompts, file contents or tool output.

    SOCKET=__SOCKET__
    TOKEN=__TOKEN__
    EVENT="${1:-unknown}"
    PAYLOAD=$(cat 2>/dev/null)
    [ -S "$SOCKET" ] || exit 0

    (
    __HELPERS__
      # The program a shell command runs ("cd x && git status" -> "git"), never its arguments.
      program() {
        line=$(printf '%s\n' "$1" | /usr/bin/head -n 1 | /usr/bin/tr ';&|' '   ')
        set -f; set -- $line; set +f
        while [ $# -gt 0 ]; do
          case "$1" in
            cd) shift; [ $# -gt 0 ] && shift ;;
            export|set|env|time|sudo|nohup|*=*) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && /usr/bin/basename -- "$1"
      }

      FILE=$(field tool_input.file_path); [ -z "$FILE" ] && FILE=$(field tool_input.notebook_path)
      [ -n "$FILE" ] && FILE=$(/usr/bin/basename -- "$FILE")
      HOST=$(field tool_input.url); HOST=${HOST#*://}; HOST=${HOST%%[/?#]*}; [ -n "$HOST" ] && HOST="https://$HOST"
      PROG=$(program "$(field tool_input.command)")

      BODY=$(printf '{"event":"%s","payload":{"session_id":"%s","cwd":"%s","transcript_path":"%s","tool_name":"%s","notification_type":"%s","message":"%s","error":"%s","tool_input":{"description":"%s","file_path":"%s","url":"%s","query":"%s","skill":"%s","command":"%s"}}}' \
        "$(esc "$EVENT")" "$(esc "$(field session_id)")" "$(esc "$(field cwd)")" "$(esc "$(field transcript_path)")" \
        "$(esc "$(field tool_name)")" "$(esc "$(field notification_type)")" "$(esc "$(field message)")" "$(esc "$(field error)")" \
        "$(esc "$(field tool_input.description)")" "$(esc "$FILE")" "$(esc "$HOST")" "$(esc "$(field tool_input.query)")" \
        "$(esc "$(field tool_input.skill)")" "$(esc "$PROG")")

      /usr/bin/curl -s -m 2 --unix-socket "$SOCKET" -X POST "http://localhost/claude-event" \
        -H "Content-Type: application/json" -H "X-Hook-Token: $TOKEN" \
        --data-binary "$BODY" >/dev/null 2>&1
    ) >/dev/null 2>&1 &

    exit 0

    """#.replacingOccurrences(of: "__HELPERS__", with: helpers)

    private static let statusLineTemplate = #"""
    #!/bin/sh
    # Installed by AgentDot as Claude Code's statusLine. Sends the plan limits (5-hour and
    # 7-day %, reset times), the session id and the context fill to the menu-bar app over its own
    # Unix socket. Prints nothing, so the status line stays empty. Never blocks Claude.

    SOCKET=__SOCKET__
    TOKEN=__TOKEN__
    PAYLOAD=$(cat 2>/dev/null)
    [ -z "$PAYLOAD" ] && exit 0
    [ -S "$SOCKET" ] || exit 0

    (
    __HELPERS__
      BODY=$(printf '{"session_id":"%s","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":"%s"},"seven_day":{"used_percentage":%s,"resets_at":"%s"}},"context_window":{"used_percentage":%s,"total_input_tokens":%s}}' \
        "$(esc "$(field session_id)")" \
        "$(num rate_limits.five_hour.used_percentage)" "$(esc "$(field rate_limits.five_hour.resets_at)")" \
        "$(num rate_limits.seven_day.used_percentage)" "$(esc "$(field rate_limits.seven_day.resets_at)")" \
        "$(num context_window.used_percentage)" "$(num context_window.total_input_tokens)")

      /usr/bin/curl -s -m 2 --unix-socket "$SOCKET" -X POST "http://localhost/claude-limits" \
        -H "Content-Type: application/json" -H "X-Hook-Token: $TOKEN" \
        --data-binary "$BODY" >/dev/null 2>&1
    ) >/dev/null 2>&1 &

    exit 0

    """#.replacingOccurrences(of: "__HELPERS__", with: helpers)

    static func command(for event: String, scriptPath: String) -> String {
        "\"\(scriptPath)\" \(event)"
    }

    // MARK: - Pure JSON edits (unit-tested)

    /// Adds our hook to every event that doesn't already have it, and our statusLine when there is
    /// none. Everything else is kept.
    static func adding(to settings: [String: Any], scriptPath: String, statusLinePath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(scriptPath) == true }
            }
            guard !present else { continue }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command(for: event, scriptPath: scriptPath)]]]
            if matcherEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        if settings["statusLine"] == nil {
            settings["statusLine"] = ["type": "command", "command": "\"\(statusLinePath)\""]
        }
        return settings
    }

    /// Removes only our hook commands (and our statusLine); empty groups and events are dropped.
    static func removing(from settings: [String: Any], scriptPath: String, statusLinePath: String) -> [String: Any] {
        var settings = settings
        if ownsStatusLine(settings, statusLinePath: statusLinePath) { settings["statusLine"] = nil }
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let commands = group["hooks"] as? [[String: Any]] else { return group }
                let others = commands.filter { ($0["command"] as? String)?.contains(scriptPath) != true }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(scriptPath) == true }
            }
        }
    }

    static func ownsStatusLine(_ settings: [String: Any], statusLinePath: String) -> Bool {
        ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(statusLinePath) == true
    }

    // MARK: - Files

    enum HookError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Couldn't read \(path) as JSON. Nothing was changed."
            }
        }
    }

    static func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HookError.unreadable(url.path)
        }
        return object
    }

    struct Paths {
        var settings = ClaudeHooks.defaultSettingsURL
        var script = ClaudeHooks.scriptURL
        var statusLine = ClaudeHooks.statusLineURL
        var token = ClaudeHooks.tokenURL
        var socket = EventServer.socketURL.path
    }

    /// Writes a fresh token, both scripts and the settings entries. Returns the new token.
    @discardableResult
    static func install(_ paths: Paths = Paths()) throws -> String {
        let settings = try readSettings(paths.settings)
        let fm = FileManager.default
        let folder = paths.script.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let token = makeToken()
        try writePrivate(Data(token.utf8), to: paths.token, mode: 0o600)
        try writePrivate(Data(hookScript(socketPath: paths.socket, token: token).utf8), to: paths.script, mode: 0o700)
        try writePrivate(Data(statusLineScript(socketPath: paths.socket, token: token).utf8), to: paths.statusLine, mode: 0o700)
        if paths.token == Self.tokenURL { cachedToken = .some(token) }
        try write(adding(to: settings, scriptPath: paths.script.path, statusLinePath: paths.statusLine.path), to: paths.settings)
        return token
    }

    static func uninstall(_ paths: Paths = Paths()) throws {
        let settings = try readSettings(paths.settings)
        try write(removing(from: settings, scriptPath: paths.script.path, statusLinePath: paths.statusLine.path), to: paths.settings)
        try? FileManager.default.removeItem(at: paths.script)
        try? FileManager.default.removeItem(at: paths.statusLine)
        try? FileManager.default.removeItem(at: paths.token)
        if paths.token == Self.tokenURL { cachedToken = .some(nil) }
    }

    struct InstallState: Equatable {
        var hooks = false
        /// Our statusLine is the one Claude Code runs (plan limits can arrive).
        var statusLine = false
        /// Someone else's statusLine is set, so ours wasn't installed.
        var foreignStatusLine = false
    }

    static func state(_ paths: Paths = Paths()) -> InstallState {
        guard let settings = try? readSettings(paths.settings) else { return InstallState() }
        let hooks = FileManager.default.fileExists(atPath: paths.script.path)
            && isInstalled(in: settings, scriptPath: paths.script.path)
        let ours = ownsStatusLine(settings, statusLinePath: paths.statusLine.path)
        return InstallState(hooks: hooks, statusLine: ours, foreignStatusLine: settings["statusLine"] != nil && !ours)
    }

    /// Created with the final permissions, so the secret is never readable by others, even briefly.
    private static func writePrivate(_ data: Data, to url: URL, mode: mode_t) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        fchmod(fd, mode)
    }

    /// Keeps one backup of the file as it was before AgentDot first touched it.
    private static func write(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = backupURL(for: url)
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func backupURL(for settings: URL) -> URL {
        settings.appendingPathExtension("agentdot-backup")
    }
}
