import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only: no Dock icon (LSUIElement in Info.plist does the same for the built app).
app.setActivationPolicy(.accessory)
app.run()
