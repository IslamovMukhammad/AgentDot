import Foundation

/// `--demo`: made-up sessions, tasks, limits and usage for screenshots. No hooks, no files, no
/// network. Project names are invented.
enum Demo {
    static func fill(_ model: AppModel, now: Date = Date()) {
        let sessions = [
            ClaudeSessionInfo(id: "d1", project: "weather-widget", state: .waiting,
                              activity: "Claude needs your permission to use Bash", model: "claude-opus-5-5",
                              contextPercent: 41, cwd: nil, stateSince: now.addingTimeInterval(-40)),
            ClaudeSessionInfo(id: "d2", project: "recipe-api", state: .working,
                              activity: "Run the test suite", model: "claude-sonnet-5-5",
                              contextPercent: 18, cwd: nil, stateSince: now.addingTimeInterval(-300)),
            ClaudeSessionInfo(id: "d3", project: "pixel-notes", state: .done,
                              activity: "answer ready", model: "claude-opus-5-5",
                              contextPercent: 63, cwd: nil, stateSince: now.addingTimeInterval(-20)),
        ]
        let agents = [
            SubagentInfo(id: "a1", name: "Review the parser changes", kind: "general-purpose", model: "Sonnet 5.5",
                         startedAt: now.addingTimeInterval(-134), toolUses: 12, current: "Reading Parser.swift",
                         project: "recipe-api", sessionID: "d2"),
            SubagentInfo(id: "a2", name: "Find unused assets", kind: "Explore", model: "Haiku 5.5",
                         startedAt: now.addingTimeInterval(-47), toolUses: 5, current: "Searching the code",
                         project: "recipe-api", sessionID: "d2"),
        ]
        let limits = PlanLimits(
            fiveHour: LimitWindow(percent: 72, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60).timeIntervalSince1970),
            sevenDay: LimitWindow(percent: 38, resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3600).timeIntervalSince1970),
            receivedAt: now.timeIntervalSince1970)

        func period(_ rows: [(String, Double, Int)]) -> ProjectUsagePeriod {
            let mapped = rows.map { ProjectUsageRow(project: $0.0, cost: $0.1, tokens: $0.2, cacheRead: $0.2 * 9) }
            return ProjectUsagePeriod(cost: mapped.reduce(0) { $0 + $1.cost }, tokens: mapped.reduce(0) { $0 + $1.tokens },
                                      cacheRead: mapped.reduce(0) { $0 + $1.cacheRead }, rows: mapped)
        }
        let usage = ProjectUsageSummary(
            updatedAt: now, unpriced: false,
            today: period([("recipe-api", 3.42, 412_000), ("weather-widget", 1.87, 236_000), ("pixel-notes", 0.64, 81_000)]),
            week: period([("recipe-api", 21.30, 2_480_000), ("weather-widget", 12.75, 1_530_000),
                          ("pixel-notes", 6.10, 702_000), ("trail-map", 2.05, 260_000)]),
            month: period([("recipe-api", 64.80, 7_900_000), ("weather-widget", 41.20, 5_100_000),
                           ("pixel-notes", 18.45, 2_200_000), ("trail-map", 9.90, 1_150_000), ("dotfiles", 1.35, 140_000)]))
        model.setDemo(sessions: sessions, agents: agents, limits: limits, usage: usage)
    }
}

import AppKit
import SwiftUI

/// `--demo --snapshot <folder>`: the app renders its own panel, settings and menu-bar item with
/// the demo data into PNGs (for the README), then quits. Nothing on screen is captured.
extension Demo {
    static func snapshot(_ model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let look = NSAppearance(named: appearance)
            render(PanelView(model: model, openSettings: {}), appearance: look,
                   background: .windowBackgroundColor, to: folder.appendingPathComponent("panel-\(name).png"))
            render(MenuBarPreview(limits: model.limits), appearance: look, background: .clear,
                   to: folder.appendingPathComponent("menubar-\(name).png"))
        }
        render(SettingsView(model: model, liveUsage: model.liveUsage), appearance: NSAppearance(named: .aqua),
               background: .windowBackgroundColor, to: folder.appendingPathComponent("settings.png"))
    }

    private static func render(_ view: some View, appearance: NSAppearance?, background: NSColor, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let size = host.fittingSize
        let window = KeyWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = background
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Key and active, so controls show their accent colours as in the real panel.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Two passes: SwiftUI settles its layout after the first draw.
        for _ in 0..<2 {
            host.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        appearance?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.restoreGraphicsState()
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// Offscreen but able to become key.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The three menu-bar looks side by side, drawn with the same `StatusIcon` the real item uses.
private struct MenuBarPreview: View {
    let limits: PlanLimits?

    var body: some View {
        HStack(spacing: 18) {
            item(.working, title: StatusIcon.title(limits: limits))
            item(.needsYou, title: StatusIcon.title(limits: limits))
            item(.idle, title: nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func item(_ state: OverallState, title: String?) -> some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.dot(state))
            if let title {
                Text(title).font(.system(size: NSFont.systemFontSize - 1, weight: .medium).monospacedDigit())
            }
        }
    }
}
