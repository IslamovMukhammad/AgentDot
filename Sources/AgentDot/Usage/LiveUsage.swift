import Foundation
import Security

/// OPTIONAL, OFF by default: the account-wide 5-hour and 7-day percentages from Anthropic's
/// `/api/oauth/usage`, the same numbers Claude Code's `/usage` shows. This is not inference: no
/// tokens are spent and no 5-hour window is started.
///
/// How it works (only after you turn it on in Settings, for your own account):
///   · Claude Code's login token is read from the macOS Keychain ("Claude Code-credentials"):
///     first with macOS's own `security` tool, otherwise with the Keychain API.
///   · The token is kept in memory only, until it expires: never written to disk, never logged,
///     never sent anywhere but the fixed address below. Turning the switch off drops it.
///   · One request to api.anthropic.com about every 5 minutes. A 429 honours Retry-After,
///     otherwise the app waits 2, 5, 15, 30, 60 minutes.
///   · An expired token is NOT refreshed (Claude Code does that itself); Settings says so.
///   · The endpoint is undocumented and may change at any time.
final class LiveUsage: ObservableObject {

    /// Where the login comes from. The app reads the Keychain; tests pass a mock.
    protocol CredentialSource: Sendable {
        func read() async -> Result<LiveUsageParser.Credential, Failure>
    }

    /// Sends the request. The app uses URLSession; tests pass a mock.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    struct Failure: Error, Sendable, CustomStringConvertible, Equatable {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Shown in Settings.
    @Published private(set) var status = "Off"
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            apply()
        }
    }

    /// New limits, in the statusLine shape.
    var onLimits: (([String: Any]) -> Void)?

    static let enabledKey = "settings.liveUsage"
    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let interval: TimeInterval = 300
    static let backoffSteps: [TimeInterval] = [120, 300, 900, 1800, 3600]

    private let defaults: UserDefaults
    private let credentials: CredentialSource
    private let fetch: Fetch
    private var timer: DispatchWorkItem?
    private var inFlight = false
    private(set) var failureStreak = 0
    /// In memory only, until it expires: the Keychain is asked rarely, not every 5 minutes.
    private var cachedCredential: LiveUsageParser.Credential?
    /// For tests: whether a token is held right now.
    var holdsCredential: Bool { cachedCredential != nil }

    init(defaults: UserDefaults = .standard,
         credentials: CredentialSource = KeychainCredentialSource(),
         fetch: @escaping Fetch = LiveUsage.urlSessionFetch) {
        self.defaults = defaults
        self.credentials = credentials
        self.fetch = fetch
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    func start() { apply() }

    private func apply() {
        timer?.cancel(); timer = nil
        failureStreak = 0
        cachedCredential = nil
        guard enabled else { status = "Off"; return }
        status = "Waiting for the first check…"
        schedule(after: 2)
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.poll() }
            }
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// One check. Public for tests; the app calls it from its timer.
    func poll() async {
        guard enabled, !inFlight else { return }
        inFlight = true
        let outcome = await check()
        inFlight = false
        guard enabled else { cachedCredential = nil; return }
        switch outcome {
        case .limits(let limits):
            failureStreak = 0
            status = "OK · updated \(Date().formatted(date: .omitted, time: .shortened))"
            onLimits?(limits)
            schedule(after: Self.interval)
        case .failure(let message, let retryAfter):
            failureStreak += 1
            let step = Self.backoffSteps[min(failureStreak - 1, Self.backoffSteps.count - 1)]
            let wait = max(retryAfter ?? 0, step)
            status = "\(message) · retry in \(Int(wait / 60)) min"
            schedule(after: wait)
        }
    }

    private enum Outcome {
        case limits([String: Any])
        case failure(String, retryAfter: TimeInterval?)
    }

    private func check() async -> Outcome {
        // 1) The token: the one in memory while it's valid, otherwise the Keychain.
        let credential: LiveUsageParser.Credential
        if let cached = cachedCredential, !cached.isExpired() {
            credential = cached
        } else {
            cachedCredential = nil
            switch await credentials.read() {
            case .success(let value): credential = value
            case .failure(let failure): return .failure(failure.description, retryAfter: nil)
            }
            if credential.isExpired() {
                return .failure("Claude Code login expired (open Claude Code once to refresh it)", retryAfter: nil)
            }
            cachedCredential = credential
        }

        // 2) The request, to the fixed address only.
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, http) = try await fetch(request)
            switch http.statusCode {
            case 200:
                guard let limits = LiveUsageParser.statusLineShape(from: data) else {
                    return .failure("Unexpected response format (the endpoint may have changed)", retryAfter: nil)
                }
                return .limits(limits)
            case 401, 403:
                // The token was refused: drop it, the next check reads a fresh one.
                cachedCredential = nil
                return .failure("Login rejected (\(http.statusCode)); open Claude Code once to refresh it", retryAfter: nil)
            case 429:
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                return .failure("Rate limited by the server", retryAfter: retry)
            default:
                return .failure("Server error \(http.statusCode)", retryAfter: nil)
            }
        } catch {
            return .failure("Offline or unreachable", retryAfter: nil)
        }
    }

    nonisolated static let urlSessionFetch: Fetch = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Reads Claude Code's login from the Keychain, off the main thread. Used only when Live usage
/// is on.
nonisolated struct KeychainCredentialSource: LiveUsage.CredentialSource {
    static let service = "Claude Code-credentials"

    func read() async -> Result<LiveUsageParser.Credential, LiveUsage.Failure> {
        await Task.detached(priority: .utility) { Self.readNow() }.value
    }

    /// First macOS's own `security` tool (Claude Code creates the item with it, so usually no
    /// password prompt appears), otherwise the Keychain API.
    private static func readNow() -> Result<LiveUsageParser.Credential, LiveUsage.Failure> {
        switch readViaSecurityTool() {
        case .found(let credential): return .success(credential)
        case .notFound: return .failure(.init("No Claude Code login found in Keychain"))
        case .unavailable: return readViaKeychainAPI()
        }
    }

    private enum ToolResult { case found(LiveUsageParser.Credential), notFound, unavailable }

    private static func readViaSecurityTool() -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return .unavailable }
            // `-w` sometimes prints hex (when the value has a newline or non-ASCII characters).
            if !text.hasPrefix("{"), text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
                var bytes = [UInt8]()
                var index = text.startIndex
                while index < text.endIndex {
                    let next = text.index(index, offsetBy: 2)
                    guard let byte = UInt8(text[index..<next], radix: 16) else { return .unavailable }
                    bytes.append(byte)
                    index = next
                }
                text = String(decoding: bytes, as: UTF8.self)
            }
            guard let credential = LiveUsageParser.credential(from: Data(text.utf8)) else { return .unavailable }
            return .found(credential)
        case 44:   // errSecItemNotFound
            return .notFound
        default:
            return .unavailable
        }
    }

    private static func readViaKeychainAPI() -> Result<LiveUsageParser.Credential, LiveUsage.Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        switch result {
        case errSecSuccess:
            guard let data = item as? Data, let credential = LiveUsageParser.credential(from: data) else {
                return .failure(.init("Claude Code login has an unexpected format"))
            }
            return .success(credential)
        case errSecItemNotFound:
            return .failure(.init("No Claude Code login found in Keychain"))
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .failure(.init("Keychain access was not allowed"))
        default:
            return .failure(.init("Keychain error \(result)"))
        }
    }
}
