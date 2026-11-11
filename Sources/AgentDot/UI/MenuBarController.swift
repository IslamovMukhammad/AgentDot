import AppKit
import Combine
import SwiftUI

/// The menu-bar item (a status dot plus the 5-hour %) and its panel.
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var observers: Set<AnyCancellable> = []
    private var clock: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView:
            PanelView(model: model, openSettings: { [weak self] in self?.showSettings() })
        )

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Claude sessions and usage")
        }
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &observers)
        // A reset time passing changes the icon without any new data.
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        redraw()
    }

    private func redraw() {
        guard let button = item.button else { return }
        let state = model.overall
        button.image = StatusIcon.dot(state)
        if let title = StatusIcon.title(limits: model.limits) {
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
            ])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = StatusIcon.tooltip(state)
    }

    @objc private func togglePanel() {
        popover.isShown ? popover.performClose(nil) : showPanel()
    }

    func showPanel() {
        guard let button = item.button else { return }
        model.panelOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, liveUsage: model.liveUsage)))
            window.title = "\(AppSupport.name) Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// What the menu-bar item shows. Pure parts are unit-tested.
enum StatusIcon {

    /// "72%" from the 5-hour window, or nil (dot only) when there's no current limit data.
    static func title(limits: PlanLimits?, now: Date = Date()) -> String? {
        guard let window = limits?.fiveHour, !window.isExpired(now: now) else { return nil }
        return "\(Int(window.percent.rounded()))%"
    }

    static func color(_ state: OverallState) -> NSColor {
        switch state {
        case .working: .systemYellow
        case .needsYou: .systemRed
        case .idle: .systemGray
        }
    }

    static func tooltip(_ state: OverallState) -> String {
        switch state {
        case .working: "Claude is working"
        case .needsYou: "A Claude session needs you"
        case .idle: "No Claude session is working"
        }
    }

    static func dot(_ state: OverallState) -> NSImage {
        let color = color(state)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
