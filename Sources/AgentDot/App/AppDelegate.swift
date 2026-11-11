import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        model = AppModel(demo: arguments.contains("--demo"))
        menuBar = MenuBarController(model: model)
        model.start()
        if model.isDemo, let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            Demo.snapshot(model, to: URL(fileURLWithPath: arguments[index + 1]))
            NSApp.terminate(nil)
            return
        }
        if arguments.contains("--open-panel") { menuBar.showPanel() }
        if arguments.contains("--open-settings") { menuBar.showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
