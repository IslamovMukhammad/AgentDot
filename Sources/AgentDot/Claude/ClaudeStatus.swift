import Foundation

/// One Claude Code session as the panel shows it.
struct ClaudeSessionInfo: Equatable, Identifiable {
    let id: String
    /// The folder the session started in.
    let project: String
    let state: ClaudeStatus.State
    /// The current tool in plain words ("editing PanelView.swift"), or a notification's text.
    let activity: String
    /// "claude-opus-5-5"; nil until the transcript has an answer.
    let model: String?
    let contextPercent: Int?
    /// Working folder: "Open ›" uses it to find the app the session runs in.
    let cwd: String?
    /// Since when the session is in its current state.
    let stateSince: Date
}

/// Builds Claude Code's state out of its hook events.
///
/// Several sessions can be open at once (one per folder), so state is kept per `session_id`:
/// otherwise one session finishing would wipe out another one's state.
final class ClaudeStatus {

    enum State: String {
        case idle, working, waiting, done, error
    }

    private final class Session {
        let id: String
        var project: String
        var state: State = .idle {
            didSet { if state != oldValue { stateSince = Date() } }
        }
        var stateSince = Date()
        /// The project name is taken from the folder the session started in, once
        /// (a later `cd` doesn't rename it).
        var projectLocked = false
        var activity = "ready"
        var runningTasks = 0
        var lastEventAt: Date
        /// So the transcript isn't read too often.
        var lastEndCheck = Date.distantPast
        var lastUsageCheck = Date.distantPast
        var lastTranscriptSize: UInt64 = 0
        /// The path the hook reported; it is only trusted after `TranscriptReader.validated`.
        var reportedTranscript: String?
        var transcriptPath: String?
        var cwd: String?
        var model: String?
        var contextTokens: Int?
        /// Claude Code's own context % from the statusLine (it knows the model's real window).
        var contextPercentReported: Int?

        var isBusy: Bool { state == .working || state == .waiting }

        var contextPercent: Int? {
            if let contextPercentReported { return contextPercentReported }
            guard let model, let contextTokens else { return nil }
            return Int((Double(contextTokens) / Double(TranscriptReader.contextWindow(for: model)) * 100).rounded())
        }

        init(id: String, project: String, now: Date) {
            self.id = id
            self.project = project
            self.lastEventAt = now
        }
    }

    private var sessions: [String: Session] = [:]
    /// statusLine data that arrived before the session's first hook (the app was just opened).
    private var pendingPercent: [String: Int] = [:]
    /// Ask the transcript whether a "working" session has really finished, when the Stop hook
    /// never arrived.
    var autoDone = true

    var sessionInfos: [ClaudeSessionInfo] {
        // Busy sessions first, then the most recently active.
        sessions.values.sorted { left, right in
            if left.isBusy != right.isBusy { return left.isBusy }
            return left.lastEventAt > right.lastEventAt
        }.map {
            ClaudeSessionInfo(id: $0.id, project: $0.project, state: $0.state, activity: $0.activity,
                              model: $0.model, contextPercent: $0.contextPercent, cwd: $0.cwd,
                              stateSince: $0.stateSince)
        }
    }

    /// Validated transcripts of the known sessions: the subagent watcher looks next to them.
    var transcripts: [(sessionID: String, project: String, path: String)] {
        sessions.values.compactMap { session in session.transcriptPath.map { (session.id, session.project, $0) } }
    }

    // MARK: - Hook events

    func handle(event: String, payload: [String: Any], now: Date = Date()) {
        let id = payload["session_id"] as? String ?? payload["cwd"] as? String ?? "default"

        if event == "SessionEnd" {
            sessions.removeValue(forKey: id)
            return
        }

        let session = sessions[id] ?? {
            let created = Session(id: id, project: Self.projectName(from: payload) ?? "—", now: now)
            created.contextPercentReported = pendingPercent.removeValue(forKey: id)
            sessions[id] = created
            return created
        }()

        if let transcript = payload["transcript_path"] as? String, transcript != session.reportedTranscript {
            // Never opened here: it is checked and read off the main thread (see transcriptReads).
            session.reportedTranscript = transcript
            session.transcriptPath = nil
            session.lastUsageCheck = .distantPast
            session.lastTranscriptSize = 0
        }
        if !session.projectLocked, let project = Self.projectName(from: payload) {
            session.project = project
            session.projectLocked = true
        }
        if let cwd = payload["cwd"] as? String { session.cwd = cwd }

        session.lastEventAt = now
        apply(event: event, to: session, payload: payload)
    }

    private func apply(event: String, to session: Session, payload: [String: Any]) {
        switch event {
        case "SessionStart":
            session.state = .idle
            session.activity = "ready"
            session.runningTasks = 0

        case "UserPromptSubmit":
            // The prompt is sent, no tool has been called yet.
            session.state = .working
            session.activity = "thinking"

        case "PreToolUse":
            session.state = .working
            let tool = payload["tool_name"] as? String ?? "tool"
            let input = payload["tool_input"] as? [String: Any]
            if Self.subagentTools.contains(tool) {
                session.runningTasks += 1
                session.activity = Self.taskCountLabel(session.runningTasks)
            } else {
                session.activity = ToolText.describe(tool: tool, input: input)
            }

        case "PostToolUse":
            session.state = .working
            // The tool finished: Claude is reading the result and picking the next step.
            session.activity = session.runningTasks > 0 ? Self.taskCountLabel(session.runningTasks) : "thinking"

        case "SubagentStop":
            session.state = .working
            session.runningTasks = max(0, session.runningTasks - 1)
            session.activity = session.runningTasks > 0
                ? Self.taskCountLabel(session.runningTasks)
                : "subtask done · continuing"

        case "Notification":
            // Only a real request (a permission, a question) counts as "needs you".
            // `idle_prompt` ("Claude is waiting for your input") arrives about a minute after an
            // answer is done; treating it as a request would turn finished sessions red.
            let kind = payload["notification_type"] as? String ?? ""
            let message = payload["message"] as? String ?? ""
            let isIdlePrompt = kind == "idle_prompt"
                || (kind.isEmpty && message.localizedCaseInsensitiveContains("waiting for your input"))
            let ignored: Set<String> = ["auth_success", "agent_completed", "elicitation_complete",
                                        "elicitation_response", "quota_auto_resume_fired",
                                        "quota_auto_resume_stale", "quota_auto_resume_disabled"]
            if isIdlePrompt || ignored.contains(kind) { break }
            session.state = .waiting
            session.activity = ToolText.shortText(message.isEmpty ? nil : message) ?? "waiting for you"

        case "StopFailure":
            // The answer ended with an API error (limit, overload, login…).
            let reason = payload["error"] as? String ?? payload["error_type"] as? String ?? ""
            session.state = .error
            session.activity = ToolText.failureText(reason, message: payload["message"] as? String)
            session.runningTasks = 0

        case "Stop":
            session.state = .done
            session.activity = "answer ready"
            session.runningTasks = 0

        default:
            break
        }
    }

    /// statusLine data: Claude Code's own context %. `true` if it changed.
    @discardableResult
    func updateContext(sessionID: String, percent: Int?) -> Bool {
        guard let percent else { return false }
        guard let session = sessions[sessionID] else {
            pendingPercent[sessionID] = percent
            if pendingPercent.count > 50, let key = pendingPercent.keys.first { pendingPercent.removeValue(forKey: key) }
            return false
        }
        guard session.contextPercentReported != percent else { return false }
        session.contextPercentReported = percent
        return true
    }

    /// Called every few seconds: settles sessions whose last hook never came. `true` if anything changed.
    @discardableResult
    func refresh(now: Date = Date(), fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        var changed = false
        for (id, session) in sessions {
            let silence = now.timeIntervalSince(session.lastEventAt)

            // One tool call (a long build, a test suite) can run for minutes without any hook,
            // so "working" is only given up after 15 minutes of silence.
            if session.state == .working, silence > 15 * 60 {
                session.state = .idle
                session.activity = "no session"
                session.runningTasks = 0
                changed = true
            }
            if session.state == .error, silence > 5 * 60 {
                session.state = .idle
                session.activity = "no session"
                changed = true
            }
            if session.state == .done, silence > 90 {
                session.state = .idle
                session.activity = "no session"
                changed = true
            }
            // A closed terminal or a crash sends nothing, so a waiting row can't hang forever.
            if session.state == .waiting, silence > 60 * 60 {
                sessions.removeValue(forKey: id)
                changed = true
                continue
            }
            // A deleted transcript means the session is gone. A row without a transcript at
            // all isn't a real session (a hand-sent test event, say).
            if silence > 120 {
                let alive = session.transcriptPath.map(fileExists) ?? false
                if !alive {
                    sessions.removeValue(forKey: id)
                    changed = true
                    continue
                }
            }
            // Long-idle sessions shouldn't fill the list.
            if session.state == .idle, silence > 15 * 60 {
                sessions.removeValue(forKey: id)
                changed = true
            }
        }
        return changed
    }

    // MARK: - Transcript reads (done off the main thread by the model)

    struct TranscriptRead: Equatable, Sendable {
        let sessionID: String
        let path: String
        let knownSize: UInt64
        let wantsUsage: Bool
        let wantsEnd: Bool
    }

    /// Which transcripts to look at now: model and context fill (at most every 5 s, parsed only
    /// when the file grew), and a "working" session silent for 20 s, because the Stop hook doesn't
    /// always arrive and the session would stay "working" forever (at most every 10 s).
    func transcriptReads(now: Date = Date()) -> [TranscriptRead] {
        sessions.values.compactMap { session in
            guard let path = session.reportedTranscript else { return nil }
            let wantsUsage = now.timeIntervalSince(session.lastUsageCheck) > 5
            let wantsEnd = autoDone && session.state == .working
                && now.timeIntervalSince(session.lastEventAt) > 20
                && now.timeIntervalSince(session.lastEndCheck) > 10
            guard wantsUsage || wantsEnd else { return nil }
            if wantsUsage { session.lastUsageCheck = now }
            if wantsEnd { session.lastEndCheck = now }
            return TranscriptRead(sessionID: session.id, path: path, knownSize: session.lastTranscriptSize,
                                  wantsUsage: wantsUsage, wantsEnd: wantsEnd)
        }
    }

    /// The result of a background read. `result.validPath` is nil when the reported path was refused.
    @discardableResult
    func apply(_ read: TranscriptRead, result: TranscriptReader.Result, now: Date = Date()) -> Bool {
        guard let session = sessions[read.sessionID], session.reportedTranscript == read.path else { return false }
        session.transcriptPath = result.validPath
        guard result.validPath != nil else { return false }
        session.lastTranscriptSize = result.size
        var changed = false
        if let usage = result.usage, usage.model != session.model || usage.contextTokens != session.contextTokens {
            session.model = usage.model
            session.contextTokens = usage.contextTokens
            changed = true
        }
        if let end = result.end, end != .running, session.state == .working,
           now.timeIntervalSince(session.lastEventAt) > 20 {
            session.state = .done
            session.activity = end == .interrupted ? "stopped" : "answer ready"
            session.runningTasks = 0
            session.lastEventAt = now
            changed = true
        }
        return changed
    }

    // MARK: - Helpers

    private static let subagentTools: Set<String> = ["Task", "Agent"]

    private static func taskCountLabel(_ count: Int) -> String {
        count == 1 ? "1 task running" : "\(count) tasks running"
    }

    private static func projectName(from payload: [String: Any]) -> String? {
        guard let cwd = payload["cwd"] as? String else { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

/// Plain-words text for tools, notifications and failures.
nonisolated enum ToolText {

    /// A readable line out of the tool name and its input. Hooks hand over the tool input;
    /// ignoring it would give empty lines like "running a command".
    static func describe(tool: String, input: [String: Any]?) -> String {
        switch tool {
        case "Bash":
            // Claude's own description reads best; paths are cut to the file name.
            if let description = input?["description"] as? String, !description.isEmpty {
                return shorten(stripPaths(description), limit: 64)
            }
            if let command = input?["command"] as? String { return describeCommand(command) }
            return "running a command"
        case "Read":
            return fileName(from: input).map { "reading \($0)" } ?? "reading a file"
        case "Edit", "Write", "NotebookEdit":
            return fileName(from: input).map { "editing \($0)" } ?? "editing a file"
        case "Grep":
            return "searching the code"
        case "Glob":
            return "looking for files"
        case "WebSearch":
            if let query = input?["query"] as? String { return "searching: \(shorten(query, limit: 48))" }
            return "searching the web"
        case "WebFetch":
            if let url = input?["url"] as? String { return "fetching \(URL(string: url)?.host ?? "a page")" }
            return "fetching a page"
        case "TodoWrite":
            return "updating the plan"
        case "Skill":
            if let skill = input?["skill"] as? String { return "using the \(skill) skill" }
            return "using a skill"
        case "AskUserQuestion":
            return "asking you a question"
        case "ToolSearch":
            return "loading tools"
        case "EnterPlanMode", "ExitPlanMode":
            return "planning"
        default:
            if tool.hasPrefix("mcp__") { return describeMCP(tool) }
            return "using \(tool)"
        }
    }

    /// Raw names like "mcp__Some_Browser__browser_batch" are jargon at arm's length.
    private static func describeMCP(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        let server = parts.count > 1 ? parts[1] : tool
        let lower = server.lowercased()
        if lower.contains("browser") || lower.contains("chrome") { return "using the browser" }
        if lower.contains("simulator") { return "using the iOS Simulator" }
        if lower.contains("terminal") { return "using the terminal" }
        let readable = server.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        // A long generated id (a UUID, say) gets a generic label.
        if readable.count > 28 || readable.filter(\.isNumber).count > 6 { return "using a connected tool" }
        return "using \(readable)"
    }

    private static func fileName(from input: [String: Any]?) -> String? {
        guard let path = input?["file_path"] as? String ?? input?["notebook_path"] as? String else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Absolute paths become file names ("/a/b/c.swift" → "c.swift"); `~/…` and `$HOME/…` too.
    private static func stripPaths(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()"))
            guard trimmed.contains("/"), trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("$") else { return w }
            let last = (trimmed as NSString).lastPathComponent
            return last.isEmpty ? "files" : last
        }.joined(separator: " ")
    }

    /// A command without a description: a plain verb from its first word, never the raw text.
    private static func describeCommand(_ command: String) -> String {
        let line = command.split(separator: "\n").first.map(String.init) ?? command
        var words = line.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "&" || $0 == "|" }).map(String.init)
        while let first = words.first, ["cd", "export", "set", "env", "time", "sudo", "nohup"].contains(first) {
            words.removeFirst()
            if first == "cd", !words.isEmpty { words.removeFirst() }
        }
        guard let raw = words.first else { return "running a command" }
        switch (raw as NSString).lastPathComponent.lowercased() {
        case "git": return "using git"
        case "xcodebuild", "swift", "swiftc": return "building the app"
        case "python", "python3", "node", "ruby": return "running a script"
        case "ls", "cat", "head", "tail", "sed", "awk", "find", "wc", "stat", "file": return "reading files"
        case "grep", "rg", "ag": return "searching the code"
        case "curl", "wget": return "calling the network"
        case "npm", "pnpm", "yarn", "brew", "pip", "pip3": return "managing packages"
        case "open", "osascript": return "controlling an app"
        case "pkill", "kill", "killall": return "stopping a process"
        case "rm", "mv", "cp", "mkdir", "touch", "ditto", "chmod": return "managing files"
        case "sleep", "until", "while": return "waiting"
        default: return "running a command"
        }
    }

    static func failureText(_ reason: String, message: String?) -> String {
        switch reason {
        case "rate_limit": return "limit reached"
        case "overloaded": return "API overloaded"
        case "authentication_failed": return "login problem"
        case "billing_error": return "billing problem"
        case "server_error": return "server error"
        default:
            if let message = shortText(message) { return message }
            return reason.isEmpty ? "API error" : reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func shorten(_ text: String, limit: Int) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    static func shortText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 110 ? String(single.prefix(110)) + "…" : single
    }

    /// "claude-opus-5-5" → "Opus 5.5"
    static func prettyModel(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().prefix(while: { $0.allSatisfy(\.isNumber) && $0.count <= 2 })
        let title = name.prefix(1).uppercased() + name.dropFirst()
        return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
    }
}
