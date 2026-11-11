import Foundation

/// Pure parsing for Live usage: the `/api/oauth/usage` answer and Claude Code's login record.
nonisolated enum LiveUsageParser {

    /// The answer's `five_hour` and `seven_day` windows, in the statusLine shape
    /// (`ClaudeLimits.ingest` reads that). nil when neither is there.
    static func statusLineShape(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var limits: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let dict = object[key] as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue,
                  utilization.isFinite else { continue }
            // The endpoint already returns a percentage (1.0 = 1 %), it isn't multiplied again.
            var entry: [String: Any] = ["used_percentage": min(max(utilization, 0), 100)]
            if let reset = ISODate.epoch(dict["resets_at"]) { entry["resets_at"] = reset }
            limits[key] = entry
        }
        return limits.isEmpty ? nil : ["rate_limits": limits]
    }

    /// Claude Code's login. Its description never shows the token, so it can't end up in a log.
    struct Credential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let accessToken: String
        /// Milliseconds; may be missing.
        let expiresAtMs: Double?

        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAtMs else { return false }
            return expiresAtMs / 1000 <= now.timeIntervalSince1970 + 30
        }

        var description: String { "Credential(redacted)" }
        var debugDescription: String { description }
    }

    /// The login record: `{"claudeAiOauth": {"accessToken": "...", "expiresAt": 1234567890123, ...}}`.
    static func credential(from data: Data) -> Credential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return Credential(accessToken: token, expiresAtMs: (oauth["expiresAt"] as? NSNumber)?.doubleValue)
    }
}
