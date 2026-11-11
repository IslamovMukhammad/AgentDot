import Foundation
import Testing
@testable import AgentDot

@Suite("Plan limits")
struct PlanLimitsTests {

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func readsTheStatusLineShape() {
        let limits = ClaudeLimits(fileURL: nil)
        let result = limits.ingest(["rate_limits": [
            "five_hour": ["used_percentage": 72.4, "resets_at": 1_800_003_600],
            "seven_day": ["used_percentage": 140, "resets_at": "2027-01-15T08:00:00.000Z"],
        ]], now: now)
        #expect(result?.fiveHour == LimitWindow(percent: 72.4, resetsAt: 1_800_003_600))
        #expect(result?.sevenDay?.percent == 100)          // clamped
        #expect(result?.sevenDay?.resetsAt == ISODate.parse("2027-01-15T08:00:00.000Z")?.timeIntervalSince1970)
        #expect(limits.latest == result)
    }

    @Test func noLimitsChangeNothing() {
        let limits = ClaudeLimits(fileURL: nil)
        #expect(limits.ingest(["session_id": "x"], now: now) == nil)
        #expect(limits.ingest(["rate_limits": ["five_hour": ["used_percentage": NSNull()]]], now: now) == nil)
        #expect(limits.latest == nil)
    }

    @Test func epochParsing() {
        #expect(ISODate.epoch(12.5) == 12.5)
        #expect(ISODate.epoch("1800000000") == 1_800_000_000)
        #expect(ISODate.epoch("2026-11-11T18:00:00Z") == ISODate.parse("2026-11-11T18:00:00Z")?.timeIntervalSince1970)
        #expect(ISODate.epoch("") == nil)
        #expect(ISODate.epoch("soon") == nil)
    }

    @Test func menuBarTitleOnlyWithCurrentData() {
        #expect(StatusIcon.title(limits: nil, now: now) == nil)
        let current = PlanLimits(fiveHour: LimitWindow(percent: 71.6, resetsAt: now.timeIntervalSince1970 + 60),
                                 sevenDay: nil, receivedAt: 0)
        #expect(StatusIcon.title(limits: current, now: now) == "72%")
        let expired = PlanLimits(fiveHour: LimitWindow(percent: 90, resetsAt: now.timeIntervalSince1970 - 1),
                                 sevenDay: nil, receivedAt: 0)
        #expect(StatusIcon.title(limits: expired, now: now) == nil)
        let weekOnly = PlanLimits(fiveHour: nil, sevenDay: LimitWindow(percent: 10, resetsAt: nil), receivedAt: 0)
        #expect(StatusIcon.title(limits: weekOnly, now: now) == nil)
    }

    @Test func savesAndRestores() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("limits.json")
        let limits = ClaudeLimits(fileURL: file)
        limits.ingest(["rate_limits": ["five_hour": ["used_percentage": 33]]], now: now)
        #expect(await waitUntil(seconds: 6) { FileManager.default.fileExists(atPath: file.path) })
        #expect(ClaudeLimits(fileURL: file).latest?.fiveHour?.percent == 33)
    }
}

// MARK: - Live usage (mocks only: the real Keychain is never read in tests)

/// Counts reads and hands out a fixed login.
nonisolated final class MockCredentials: LiveUsage.CredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    let result: Result<LiveUsageParser.Credential, LiveUsage.Failure>

    init(_ result: Result<LiveUsageParser.Credential, LiveUsage.Failure>) { self.result = result }

    var reads: Int { lock.withLock { _reads } }

    func read() async -> Result<LiveUsageParser.Credential, LiveUsage.Failure> {
        lock.withLock { _reads += 1 }
        return result
    }
}

/// Records requests and answers with a fixed status and body.
nonisolated final class MockServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var status = 200
    var body = Data()
    var headers: [String: String] = [:]

    var requests: [URLRequest] { lock.withLock { _requests } }

    var fetch: LiveUsage.Fetch {
        { [self] request in
            lock.withLock { _requests.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        }
    }
}

@Suite("Live usage", .serialized)
struct LiveUsageTests {

    static let fakeToken = "test-token-not-real"

    private func defaults() -> UserDefaults {
        let name = "AgentDotTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private let goodBody = Data(#"{"five_hour":{"utilization":41.0,"resets_at":"2026-11-11T18:00:00+00:00"},"seven_day":{"utilization":9.5,"resets_at":null}}"#.utf8)

    @Test func offByDefaultAndNeverReadsTheLogin() async {
        let credentials = MockCredentials(.success(.init(accessToken: Self.fakeToken, expiresAtMs: nil)))
        let server = MockServer()
        let live = LiveUsage(defaults: defaults(), credentials: credentials, fetch: server.fetch)
        #expect(!live.enabled)
        live.start()
        await live.poll()
        #expect(credentials.reads == 0)
        #expect(server.requests.isEmpty)
        #expect(live.status == "Off")
    }

    @Test func whenOnItAsksTheFixedAddressAndFeedsTheLimits() async {
        let credentials = MockCredentials(.success(.init(accessToken: Self.fakeToken, expiresAtMs: nil)))
        let server = MockServer()
        server.body = goodBody
        let store = defaults()
        let live = LiveUsage(defaults: store, credentials: credentials, fetch: server.fetch)
        var received: [String: Any]?
        live.onLimits = { received = $0 }
        live.enabled = true
        #expect(store.bool(forKey: LiveUsage.enabledKey))
        await live.poll()

        #expect(server.requests.count == 1)
        let request = server.requests.first
        #expect(request?.url == URL(string: "https://api.anthropic.com/api/oauth/usage"))
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.fakeToken)")
        let parsed = received.flatMap { ClaudeLimits.parse($0, source: .live, now: Date()) }
        #expect(parsed?.fiveHour?.percent == 41)
        #expect(parsed?.sevenDay?.percent == 9.5)
        #expect(parsed?.sevenDay?.resetsAt == nil)
        #expect(live.status.hasPrefix("OK"))
        #expect(!live.status.contains(Self.fakeToken))

        // The token is reused from memory, not read again.
        await live.poll()
        #expect(credentials.reads == 1)
        #expect(server.requests.count == 2)

        // Turning it off drops the token.
        live.enabled = false
        #expect(!live.holdsCredential)
    }

    @Test func refusedLoginIsDroppedAndBackoffApplies() async {
        let credentials = MockCredentials(.success(.init(accessToken: Self.fakeToken, expiresAtMs: nil)))
        let server = MockServer()
        server.status = 401
        let live = LiveUsage(defaults: defaults(), credentials: credentials, fetch: server.fetch)
        live.enabled = true
        await live.poll()
        #expect(!live.holdsCredential)
        #expect(live.status.contains("Login rejected"))
        #expect(live.status.contains("retry in 2 min"))
        #expect(!live.status.contains(Self.fakeToken))

        server.status = 429
        server.headers = ["Retry-After": "1200"]
        await live.poll()
        #expect(live.failureStreak == 2)
        #expect(live.status.contains("Rate limited"))
        #expect(live.status.contains("retry in 20 min"))
        #expect(credentials.reads == 2)
    }

    @Test func expiredOrMissingLogin() async {
        let expired = MockCredentials(.success(.init(accessToken: Self.fakeToken, expiresAtMs: 1000)))
        let server = MockServer()
        let live = LiveUsage(defaults: defaults(), credentials: expired, fetch: server.fetch)
        live.enabled = true
        await live.poll()
        #expect(server.requests.isEmpty)
        #expect(live.status.contains("expired"))
        #expect(!live.holdsCredential)

        let missing = MockCredentials(.failure(.init("No Claude Code login found in Keychain")))
        let other = LiveUsage(defaults: defaults(), credentials: missing, fetch: server.fetch)
        other.enabled = true
        await other.poll()
        #expect(server.requests.isEmpty)
        #expect(other.status.hasPrefix("No Claude Code login"))
    }

    @Test func parserAndRedaction() {
        let record = Data(#"{"claudeAiOauth":{"accessToken":"test-token-not-real","expiresAt":1900000000000,"refreshToken":"r"}}"#.utf8)
        let credential = LiveUsageParser.credential(from: record)
        #expect(credential?.accessToken == Self.fakeToken)
        #expect(credential?.isExpired(now: Date(timeIntervalSince1970: 1_800_000_000)) == false)
        #expect(credential?.isExpired(now: Date(timeIntervalSince1970: 1_900_000_000)) == true)
        #expect(!String(describing: credential!).contains(Self.fakeToken))
        #expect(!"\(credential!)".contains(Self.fakeToken))
        #expect(LiveUsageParser.credential(from: Data("{}".utf8)) == nil)
        #expect(LiveUsageParser.statusLineShape(from: Data(#"{"other":1}"#.utf8)) == nil)
        let shape = LiveUsageParser.statusLineShape(from: Data(#"{"five_hour":{"utilization":250}}"#.utf8))
        #expect(((shape?["rate_limits"] as? [String: Any])?["five_hour"] as? [String: Any])?["used_percentage"] as? Double == 100)
    }
}
