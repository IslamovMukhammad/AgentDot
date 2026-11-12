import AppKit
import Darwin
import Foundation
import Testing
@testable import AgentDot

@Suite("Open: finding the app a session runs in")
struct OpenerWalkTests {

    // claude (100) → login (200, root-owned) → Terminal (300) → launchd (1)
    let parents: [pid_t: pid_t] = [100: 200, 200: 300, 300: 1]

    @Test func walksPastLoginToTerminal() {
        let app = SessionOpener.ownerApp(of: 100, parent: { parents[$0] }, isApp: { $0 == 300 })
        #expect(app == 300)
    }

    @Test func aParentLookupThatFailsOnRootStopsTheWalk() {
        // What the old proc_pidinfo call did for root-owned login: no parent, so no app.
        let oldLookup: (pid_t) -> pid_t? = { $0 == 200 ? nil : parents[$0] }
        #expect(SessionOpener.ownerApp(of: 100, parent: oldLookup, isApp: { $0 == 300 }) == nil)
    }

    @Test func neverReachesLaunchdAndStopsAfter24Steps() {
        #expect(SessionOpener.ownerApp(of: 100, parent: { parents[$0] }, isApp: { _ in false }) == nil)
        var asked = 0
        let endless: (pid_t) -> pid_t? = { asked += 1; return $0 + 1 }
        #expect(SessionOpener.ownerApp(of: 10, parent: endless, isApp: { _ in false }) == nil)
        #expect(asked == 24)
    }

    @Test func realParentLookup() {
        #expect(SessionOpener.parentPID(of: getpid()) == getppid())
        // launchd is owned by root: the old call refused it, sysctl answers (its parent is 0).
        #expect(SessionOpener.parentPID(of: 1) == 0)
        #expect(SessionOpener.parentPID(of: 999_999) == nil)
    }
}

/// Opt-in live check (skipped unless LIVE_OPEN_CWD is set): a process named `claude` started in
/// that folder from a Terminal window must lead to Terminal, then Terminal is brought forward.
@Suite("Open: live Terminal check")
struct OpenerLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_OPEN_CWD"] != nil))
    func terminalSessionLeadsToTerminal() async throws {
        let cwd = try #require(ProcessInfo.processInfo.environment["LIVE_OPEN_CWD"])
        let terminal = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first)
        #expect(SessionOpener.ownerAppPID(forCwd: cwd) == terminal.processIdentifier)
        SessionOpener.open(cwd: cwd)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.Terminal" {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal")
    }
}
