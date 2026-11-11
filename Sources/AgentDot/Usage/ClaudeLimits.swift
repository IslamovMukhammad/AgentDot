import Foundation

nonisolated struct LimitWindow: Codable, Equatable, Sendable {
    /// 0…100
    var percent: Double
    /// Unix epoch seconds; may be missing.
    var resetsAt: Double?

    func isExpired(now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now.timeIntervalSince1970
    }
}

nonisolated struct PlanLimits: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case statusLine, live }
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    /// When it arrived (epoch seconds), so old data is shown as old.
    var receivedAt: Double
    var source: Source = .statusLine
}

/// The 5-hour and 7-day plan limits.
///
/// Source A is Claude Code's statusLine update (terminal Claude Code only; hooks don't carry it).
/// Source B is the optional Live usage check. Rules:
///   · no polling for source A: data comes only when Claude Code sends it;
///   · written to disk (atomically) only when a value changed;
///   · `rate_limits` exists only on Pro/Max plans and after the first answer; without it the
///     section stays hidden;
///   · a window past its `resets_at` is shown as reset, never as current.
final class ClaudeLimits {

    private(set) var latest: PlanLimits?
    private let fileURL: URL?
    private var saveWork: DispatchWorkItem?

    static var defaultFileURL: URL { AppSupport.directory.appendingPathComponent("plan-limits.json") }

    /// `fileURL` nil: memory only (tests, demo).
    init(fileURL: URL? = ClaudeLimits.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(PlanLimits.self, from: data) {
            latest = stored
        }
    }

    /// Takes the limits out of a statusLine-shaped object. Returns the new value, or nil when
    /// there are no limits in it (a plan without them): then nothing changes.
    @discardableResult
    func ingest(_ object: [String: Any], source: PlanLimits.Source = .statusLine, now: Date = Date()) -> PlanLimits? {
        guard let limits = Self.parse(object, source: source, now: now) else { return nil }
        let changed = latest?.fiveHour != limits.fiveHour || latest?.sevenDay != limits.sevenDay
        latest = limits
        if changed { scheduleSave() }
        return limits
    }

    nonisolated static func parse(_ object: [String: Any], source: PlanLimits.Source, now: Date) -> PlanLimits? {
        guard let limits = object["rate_limits"] as? [String: Any] else { return nil }
        let value = PlanLimits(fiveHour: window(limits["five_hour"]), sevenDay: window(limits["seven_day"]),
                               receivedAt: now.timeIntervalSince1970, source: source)
        return value.fiveHour == nil && value.sevenDay == nil ? nil : value
    }

    nonisolated private static func window(_ value: Any?) -> LimitWindow? {
        guard let dict = value as? [String: Any],
              let percent = (dict["used_percentage"] as? NSNumber)?.doubleValue,
              percent.isFinite
        else { return nil }
        return LimitWindow(percent: min(max(percent, 0), 100), resetsAt: ISODate.epoch(dict["resets_at"]))
    }

    /// statusLine updates come often; writes are grouped over 2 seconds.
    private func scheduleSave() {
        guard let fileURL else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let latest = self?.latest, let data = try? JSONEncoder().encode(latest) else { return }
                AppSupport.write(data, to: fileURL)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
