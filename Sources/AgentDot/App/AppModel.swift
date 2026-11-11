import Combine
import Foundation

/// The menu-bar dot: the most urgent session wins.
enum OverallState: Equatable {
    case idle, working, needsYou

    static func from(_ sessions: [ClaudeSessionInfo]) -> OverallState {
        if sessions.contains(where: { $0.state == .waiting }) { return .needsYou }
        if sessions.contains(where: { $0.state == .working }) { return .working }
        return .idle
    }
}

/// Everything the panel shows, and the wiring between the sources.
final class AppModel: ObservableObject {

    @Published private(set) var sessions: [ClaudeSessionInfo] = []
    @Published private(set) var agents: [SubagentInfo] = []
    @Published private(set) var limits: PlanLimits?
    @Published private(set) var usage: ProjectUsageSummary?
    @Published private(set) var hooks = ClaudeHooks.InstallState()
    @Published private(set) var hookError: String?
    @Published var needsYouBanner: Bool {
        didSet {
            defaults.set(needsYouBanner, forKey: Self.bannerKey)
            if needsYouBanner { notifier.requestPermission() }
        }
    }

    let liveUsage: LiveUsage
    let isDemo: Bool

    var overall: OverallState { OverallState.from(sessions) }
    var serverError: String? { server.lastError }

    static let bannerKey = "settings.needsYouBanner"

    private let defaults: UserDefaults
    private let server = EventServer()
    private let status = ClaudeStatus()
    private let planLimits: ClaudeLimits
    private let projectUsage: ProjectUsage
    private let notifier = NeedsYouNotifier()
    private let readQueue = DispatchQueue(label: "AgentDot.transcripts", qos: .utility)
    private let agentQueue = DispatchQueue(label: "AgentDot.subagents", qos: .utility)
    private let scanner = SubagentScanner()
    private var agentScanBusy = false
    private var timer: Timer?

    init(demo: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isDemo = demo
        needsYouBanner = defaults.object(forKey: Self.bannerKey) as? Bool ?? true
        liveUsage = LiveUsage(defaults: defaults)
        planLimits = ClaudeLimits(fileURL: demo ? nil : ClaudeLimits.defaultFileURL)
        projectUsage = ProjectUsage(fileURL: demo ? nil : ProjectUsage.defaultFileURL)
    }

    func start() {
        if isDemo {
            Demo.fill(self)
            return
        }
        limits = planLimits.latest
        refreshHookState()

        server.onRequest = { [weak self] path, object in self?.receive(path: path, object: object) }
        server.start()

        liveUsage.onLimits = { [weak self] object in
            guard let self, let next = self.planLimits.ingest(object, source: .live) else { return }
            self.limits = next
        }
        liveUsage.start()

        projectUsage.onChange = { [weak self] summary in self?.usage = summary }
        projectUsage.start()

        if needsYouBanner { notifier.requestPermission() }

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.5
    }

    func stop() {
        timer?.invalidate()
        server.stop()
    }

    /// The panel was opened: fresh usage numbers (spaced at least 60 s apart).
    func panelOpened() {
        guard !isDemo else { return }
        projectUsage.requestScan()
        refreshHookState()
    }

    // MARK: - Hooks

    func installHooks() {
        do {
            try ClaudeHooks.install()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookState()
    }

    func removeHooks() {
        do {
            try ClaudeHooks.uninstall()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
        refreshHookState()
    }

    private func refreshHookState() {
        guard !isDemo else { return }
        hooks = ClaudeHooks.state()
    }

    // MARK: - Incoming

    private func receive(path: String, object: [String: Any]) {
        switch path {
        case "/claude-event":
            guard let event = object["event"] as? String else { return }
            status.handle(event: event, payload: object["payload"] as? [String: Any] ?? [:])
            if event == "Stop" || event == "StopFailure" || event == "SessionEnd" { projectUsage.requestScan() }
            publishSessions()
            readTranscripts()
        case "/claude-limits":
            if let next = planLimits.ingest(object, source: .statusLine) { limits = next }
            if let id = object["session_id"] as? String {
                let percent = ((object["context_window"] as? [String: Any])?["used_percentage"] as? NSNumber)
                    .map { Int($0.doubleValue.rounded()) }
                if status.updateContext(sessionID: id, percent: percent) { publishSessions() }
            }
        default:
            break
        }
    }

    private func tick() {
        if status.refresh() { publishSessions() }
        readTranscripts()
        scanAgents()
    }

    private func publishSessions() {
        let next = status.sessionInfos
        guard next != sessions else { return }
        if needsYouBanner { notifier.notifyNewlyWaiting(old: sessions, new: next) }
        sessions = next
    }

    /// Transcripts are validated and read on a background queue, never on the main thread.
    private func readTranscripts() {
        for read in status.transcriptReads() {
            readQueue.async { [weak self] in
                let result = TranscriptReader.read(read)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.status.apply(read, result: result) { self.publishSessions() }
                    }
                }
            }
        }
    }

    private func scanAgents() {
        guard !agentScanBusy else { return }
        let transcripts = status.transcripts
        guard !transcripts.isEmpty || !agents.isEmpty else { return }
        agentScanBusy = true
        let scanner = self.scanner
        agentQueue.async { [weak self] in
            let found = scanner.scan(sessions: transcripts)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.agentScanBusy = false
                    if found != self.agents { self.agents = found }
                }
            }
        }
    }

    // MARK: - Demo

    func setDemo(sessions: [ClaudeSessionInfo], agents: [SubagentInfo], limits: PlanLimits?, usage: ProjectUsageSummary?) {
        self.sessions = sessions
        self.agents = agents
        self.limits = limits
        self.usage = usage
        self.hooks = ClaudeHooks.InstallState(hooks: true, statusLine: true, foreignStatusLine: false)
    }
}
