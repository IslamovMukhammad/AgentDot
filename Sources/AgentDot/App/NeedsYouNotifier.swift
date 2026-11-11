import Foundation
import UserNotifications

/// A macOS banner when a session starts waiting for you (a permission, a question). Clicking it
/// brings that session forward. Can be turned off in Settings.
final class NeedsYouNotifier: NSObject, UNUserNotificationCenterDelegate {

    /// Sessions that are waiting now and weren't before. Pure, unit-tested.
    nonisolated static func newlyWaiting(old: [ClaudeSessionInfo], new: [ClaudeSessionInfo]) -> [ClaudeSessionInfo] {
        let waitingBefore = Set(old.filter { $0.state == .waiting }.map(\.id))
        return new.filter { $0.state == .waiting && !waitingBefore.contains($0.id) }
    }

    /// UNUserNotificationCenter needs a real app bundle (not `swift test` or `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app" ? nil : .current()
    }

    func requestPermission() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyNewlyWaiting(old: [ClaudeSessionInfo], new: [ClaudeSessionInfo]) {
        guard let center else { return }
        for session in Self.newlyWaiting(old: old, new: new) {
            let content = UNMutableNotificationContent()
            content.title = "\(session.project) needs you"
            content.body = session.activity
            content.sound = .default
            if let cwd = session.cwd { content.userInfo = ["cwd": cwd] }
            let request = UNNotificationRequest(identifier: "needs-you-\(session.id)", content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let cwd = response.notification.request.content.userInfo["cwd"] as? String
        await MainActor.run { SessionOpener.open(cwd: cwd) }
    }

    /// Show the banner even while the panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
