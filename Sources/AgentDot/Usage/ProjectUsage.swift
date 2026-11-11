import Foundation

// Tokens and an ESTIMATED cost per project (Today / 7 days / 30 days). The source is Claude
// Code's own transcripts: ~/.claude/projects/**/*.jsonl, subagent files included. No network,
// no keys, no tokens.
//
// Rules:
//   · incremental: each file's read offset is kept, so the next scan reads only new lines; the
//     first scan can be large and runs on a background queue;
//   · the same answer is written several times (block by block) and copied into another file
//     when a session is resumed, so records are kept by `message.id` (the copy with the most
//     output tokens wins);
//   · the cost is an estimate at list prices (API equivalent), not what a subscription costs;
//     a model without a known price adds no cost and marks the total as incomplete;
//   · no timer: one scan after launch, after a session stops (at least 60 s apart), and when
//     the panel is opened (same spacing).

// MARK: - Prices (USD per million tokens). Source: the public Claude pricing page, 2026-10-15

nonisolated struct ModelPrice: Sendable, Equatable {
    let input: Double, output: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double
}

nonisolated enum ClaudePricing {
    /// The price for a model id, or nil when unknown. `promptTokens` matters only for Haiku 5.5
    /// (a higher rate above 100k).
    static func price(model: String, promptTokens: Int) -> ModelPrice? {
        let id = model.lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { id.contains($0) } }

        if has("fable-5-1", "mythos-5-1") { return ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25) }
        if has("fable-5", "mythos-5") { return ModelPrice(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1) }
        if has("opus-5-5") { return ModelPrice(input: 4, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20) }
        if has("opus-4-1", "opus-4-0", "opus-4-2025", "claude-opus-4-20") { return ModelPrice(input: 15, output: 75, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5) }
        if has("opus-5", "opus-4") { return ModelPrice(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5) }
        // Claude Code's own cost figure uses $0.20 for Sonnet 5.x cache reads; matching it keeps
        // this estimate in line with what Claude Code shows.
        if has("sonnet-5") { return ModelPrice(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.20) }
        if has("sonnet-4", "sonnet-3-7") { return ModelPrice(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30) }
        if has("haiku-5-5") {
            return promptTokens > 100_000
                ? ModelPrice(input: 0.5, output: 2.5, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05)
                : ModelPrice(input: 0.1, output: 0.5, cacheWrite5m: 0.125, cacheWrite1h: 0.2, cacheRead: 0.01)
        }
        if has("haiku-4-5") { return ModelPrice(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10) }
        if has("haiku-3-5") { return ModelPrice(input: 0.8, output: 4, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08) }
        return nil
    }

    static func cost(model: String, input: Int, output: Int, cacheRead: Int, write5m: Int, write1h: Int) -> Double? {
        guard let price = price(model: model, promptTokens: input + cacheRead + write5m + write1h) else { return nil }
        return (Double(input) * price.input + Double(output) * price.output + Double(cacheRead) * price.cacheRead
                + Double(write5m) * price.cacheWrite5m + Double(write1h) * price.cacheWrite1h) / 1_000_000
    }
}

// MARK: - Saved state

nonisolated struct ProjectUsageState: Codable, Sendable {
    var version = 1
    /// file path -> [read offset (bytes), file size]
    var files: [String: [Int]] = [:]
    var projects: [String] = []
    var models: [String] = []
    /// message.id -> [day (yyyymmdd), project, model, input, output, cacheRead, cacheWrite5m, cacheWrite1h]
    var records: [String: [Int]] = [:]
    /// folder name inside ~/.claude/projects -> project index
    var dirProject: [String: Int] = [:]
}

// MARK: - Result (what the panel shows)

nonisolated struct ProjectUsageRow: Equatable, Sendable, Identifiable {
    let project: String
    let cost: Double
    /// New tokens: input + cache write + output (cache reads are counted apart).
    let tokens: Int
    let cacheRead: Int
    var id: String { project }
}

nonisolated struct ProjectUsagePeriod: Equatable, Sendable {
    let cost: Double
    let tokens: Int
    let cacheRead: Int
    let rows: [ProjectUsageRow]
    static let empty = ProjectUsagePeriod(cost: 0, tokens: 0, cacheRead: 0, rows: [])
}

nonisolated struct ProjectUsageSummary: Equatable, Sendable {
    let updatedAt: Date
    /// A model without a known price was used (the cost is then too low).
    let unpriced: Bool
    let today: ProjectUsagePeriod
    let week: ProjectUsagePeriod
    let month: ProjectUsagePeriod
}

// MARK: - Scanner (background queue)

nonisolated enum ProjectUsageScan {
    static let keepDays = 35
    private static let chunk = 4 * 1024 * 1024

    static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Reads new lines and updates the state. `true` if anything changed.
    static func run(_ state: inout ProjectUsageState, root: URL = rootURL, now: Date = Date()) -> Bool {
        let fm = FileManager.default
        let cutoffDate = now.addingTimeInterval(-Double(keepDays + 1) * 86_400)
        var changed = false
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return false }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var seenPaths = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // Symlinks, FIFOs and devices are skipped: only regular files are read.
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoffDate,
                  let size = values.fileSize
            else { continue }
            let path = url.path
            seenPaths.insert(path)
            var offset = state.files[path]?.first ?? 0
            if size < offset { offset = 0 }              // the file shrank: from the start
            if size == offset { continue }
            let dir = url.standardizedFileURL.pathComponents.dropFirst(rootDepth).first ?? ""
            let result = scanFile(url, from: offset, size: size, dir: dir, state: &state, now: now)
            if result.changed { changed = true }
            state.files[path] = [result.consumed, size]
        }
        // Forget files that are gone or too old.
        for key in state.files.keys where !seenPaths.contains(key) {
            state.files.removeValue(forKey: key)
            changed = true
        }
        if prune(&state, now: now) { changed = true }
        return changed
    }

    /// Reads a file from `offset` to the end. A half-written last line is left for next time.
    private static func scanFile(_ url: URL, from offset: Int, size: Int, dir: String,
                                 state: inout ProjectUsageState, now: Date) -> (changed: Bool, consumed: Int) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return (false, offset) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var position = offset
        var carry = Data()
        var changed = false

        while position < size {
            try? handle.seek(toOffset: UInt64(position))
            guard let data = try? handle.read(upToCount: min(chunk, size - position)), !data.isEmpty else { break }
            position += data.count
            carry.append(data)

            var lineStart = carry.startIndex
            while let newline = carry[lineStart...].firstIndex(of: 0x0A) {
                if parse(line: carry[lineStart..<newline], dir: dir, state: &state, now: now) { changed = true }
                lineStart = carry.index(after: newline)
            }
            carry = Data(carry[lineStart...])
        }
        var consumed = position - carry.count
        // A last line without a newline that is complete JSON is taken.
        if !carry.isEmpty, (try? JSONSerialization.jsonObject(with: carry)) != nil {
            if parse(line: carry, dir: dir, state: &state, now: now) { changed = true }
            consumed = position
        }
        return (changed, consumed)
    }

    private static let assistantMark = Data("\"type\":\"assistant\"".utf8)
    private static let usageMark = Data("\"usage\"".utf8)

    static func parse(line: Data, dir: String, state: inout ProjectUsageState, now: Date) -> Bool {
        // Quick filter before any JSON parsing.
        guard line.range(of: usageMark) != nil, line.range(of: assistantMark) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let model = message["model"] as? String, !model.hasPrefix("<")      // <synthetic>
        else { return false }

        let id = (message["id"] as? String) ?? (object["requestId"] as? String) ?? (object["uuid"] as? String)
        guard let id, let timestamp = object["timestamp"] as? String, let date = ISODate.parse(timestamp) else { return false }
        guard date >= now.addingTimeInterval(-Double(keepDays) * 86_400) else { return false }

        func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let input = number(usage["input_tokens"])
        let output = number(usage["output_tokens"])
        let cacheRead = number(usage["cache_read_input_tokens"])
        let creation = usage["cache_creation"] as? [String: Any]
        var write5 = number(creation?["ephemeral_5m_input_tokens"])
        let write1 = number(creation?["ephemeral_1h_input_tokens"])
        if write5 + write1 == 0 { write5 = number(usage["cache_creation_input_tokens"]) }   // older format: all 5-minute
        if input + output + cacheRead + write5 + write1 == 0 { return false }

        let projectIndex: Int
        if let known = state.dirProject[dir] {
            projectIndex = known
        } else {
            projectIndex = index(of: projectName(dir: dir, cwd: object["cwd"] as? String), in: &state.projects)
            state.dirProject[dir] = projectIndex
        }
        let modelIndex = index(of: model, in: &state.models)
        let record = [dayKey(date), projectIndex, modelIndex, input, output, cacheRead, write5, write1]

        // Same id: the copy with more output tokens (the later one) stays.
        if let existing = state.records[id], existing.count == record.count, existing[4] >= output { return false }
        state.records[id] = record
        return true
    }

    private static func index(of value: String, in list: inout [String]) -> Int {
        if let i = list.firstIndex(of: value) { return i }
        list.append(value)
        return list.count - 1
    }

    /// A project name from the folder name Claude Code makes out of the path:
    /// `-Users-me-Desktop-demo-app` → "demo-app"; a worktree `…-demo-app--claude-worktrees-x` →
    /// "demo-app"; temporary folders (`-private-tmp-…`) → "tmp". Otherwise the last part of `cwd`.
    static func projectName(dir: String, cwd: String?) -> String {
        var name = dir
        if let range = name.range(of: "--claude-worktrees-") { name = String(name[..<range.lowerBound]) }
        if name.hasPrefix("-private-tmp") || name.hasPrefix("-tmp") || name.hasPrefix("-var-folders") { return "tmp" }
        if name.hasPrefix("-Users-") {
            let parts = name.dropFirst().split(separator: "-", omittingEmptySubsequences: true).map(String.init)
            // ["Users", "me", "Desktop", "demo", "app"]: drop "Users" and the user name.
            var rest = Array(parts.dropFirst(2))
            let containers: Set<String> = ["Desktop", "Documents", "Developer", "Projects", "Code", "code", "src",
                                           "dev", "repos", "GitHub", "Sites", "work"]
            if let first = rest.first, containers.contains(first), rest.count > 1 { rest.removeFirst() }
            return rest.isEmpty ? "home" : rest.joined(separator: "-")
        }
        if let cwd, !cwd.isEmpty {
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        return dir.isEmpty ? "—" : dir
    }

    /// Local day → yyyymmdd
    static func dayKey(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    private static func prune(_ state: inout ProjectUsageState, now: Date) -> Bool {
        let cutoff = dayKey(now.addingTimeInterval(-Double(keepDays) * 86_400))
        let before = state.records.count
        state.records = state.records.filter { ($0.value.first ?? 0) >= cutoff }
        return state.records.count != before
    }

    // MARK: - Totals

    static func summary(from state: ProjectUsageState, now: Date = Date(), maxRows: Int = 12) -> ProjectUsageSummary {
        let today = dayKey(now)
        let weekStart = dayKey(now.addingTimeInterval(-6 * 86_400))
        let monthStart = dayKey(now.addingTimeInterval(-29 * 86_400))

        struct Acc { var cost = 0.0, tokens = 0, cacheRead = 0 }
        var accToday: [Int: Acc] = [:], accWeek: [Int: Acc] = [:], accMonth: [Int: Acc] = [:]
        var unpriced = false

        for record in state.records.values where record.count == 8 {
            let day = record[0]
            guard day >= monthStart else { continue }
            let model = record[2] < state.models.count ? state.models[record[2]] : ""
            let input = record[3], output = record[4], cacheRead = record[5], write5 = record[6], write1 = record[7]
            let cost = ClaudePricing.cost(model: model, input: input, output: output, cacheRead: cacheRead,
                                          write5m: write5, write1h: write1)
            if cost == nil { unpriced = true }
            let fresh = input + output + write5 + write1
            func add(_ dict: inout [Int: Acc]) {
                var a = dict[record[1], default: Acc()]
                a.cost += cost ?? 0; a.tokens += fresh; a.cacheRead += cacheRead
                dict[record[1]] = a
            }
            add(&accMonth)
            if day >= weekStart { add(&accWeek) }
            if day == today { add(&accToday) }
        }

        func period(_ dict: [Int: Acc]) -> ProjectUsagePeriod {
            let rows = dict.map { key, a in
                ProjectUsageRow(project: key < state.projects.count ? state.projects[key] : "—",
                                cost: a.cost, tokens: a.tokens, cacheRead: a.cacheRead)
            }.sorted { ($0.cost, $0.tokens) > ($1.cost, $1.tokens) }
            return ProjectUsagePeriod(cost: rows.reduce(0) { $0 + $1.cost }, tokens: rows.reduce(0) { $0 + $1.tokens },
                                      cacheRead: rows.reduce(0) { $0 + $1.cacheRead }, rows: Array(rows.prefix(maxRows)))
        }
        return ProjectUsageSummary(updatedAt: now, unpriced: unpriced,
                                   today: period(accToday), week: period(accWeek), month: period(accMonth))
    }
}

// MARK: - Main actor: schedule, save, publish

final class ProjectUsage {

    private(set) var latest: ProjectUsageSummary?
    var onChange: ((ProjectUsageSummary) -> Void)?

    private var state = ProjectUsageState()
    private var scanning = false
    private var lastScan = Date.distantPast
    private var pending: DispatchWorkItem?
    private let root: URL
    private let fileURL: URL?

    static var defaultFileURL: URL { AppSupport.directory.appendingPathComponent("project-usage.json") }

    init(root: URL = ProjectUsageScan.rootURL, fileURL: URL? = ProjectUsage.defaultFileURL) {
        self.root = root
        self.fileURL = fileURL
    }

    /// At launch: restore the saved index, then one scan after a short pause.
    func start() {
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(ProjectUsageState.self, from: data) {
            state = stored
            if !state.records.isEmpty {
                let summary = ProjectUsageScan.summary(from: state)
                latest = summary
                onChange?(summary)
            }
        }
        schedule(after: 5)
    }

    /// After a session stops or the panel opens: grouped over 10 s, at least 60 s apart.
    func requestScan() {
        schedule(after: max(10, 60 - Date().timeIntervalSince(lastScan)))
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scanNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One scan on a background queue. Awaitable for tests.
    func scanNow() {
        Task { await scan() }
    }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        lastScan = Date()
        let snapshot = state
        let root = self.root
        let result = await Task.detached(priority: .utility) { () -> (ProjectUsageState, ProjectUsageSummary, Bool) in
            var working = snapshot
            let changed = ProjectUsageScan.run(&working, root: root)
            return (working, ProjectUsageScan.summary(from: working), changed)
        }.value
        scanning = false
        state = result.0
        latest = result.1
        onChange?(result.1)
        if result.2, let fileURL, let data = try? JSONEncoder().encode(state) {
            AppSupport.write(data, to: fileURL)
        }
    }
}
