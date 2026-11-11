import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var liveUsage: LiveUsage

    var body: some View {
        Form {
            Section("Claude Code hooks") {
                LabeledContent("Status") {
                    Text(model.hooks.hooks ? "Installed" : "Not installed")
                        .foregroundStyle(model.hooks.hooks ? .green : .secondary)
                }
                Text("Installing adds one entry per hook event to ~/.claude/settings.json (a backup is written first, other hooks are kept). A small script then sends only the event, session, folder, tool name and a short hint to this app over a private Unix socket, with a per-install token. Never your prompts, files or tool output.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.hooks.foreignStatusLine {
                    Text("You already have a statusLine of your own, so it was left alone. Plan limits from Claude Code need this app's statusLine; Live usage below works without it.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.hookError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let error = model.serverError {
                    Text("Listener: \(error)").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button(model.hooks.hooks ? "Reinstall hooks" : "Install hooks") { model.installHooks() }
                    if model.hooks.hooks { Button("Remove hooks") { model.removeHooks() } }
                }
            }

            Section("Notifications") {
                Toggle("Show a banner when a session needs you", isOn: $model.needsYouBanner)
            }

            Section("Live usage (optional)") {
                Toggle("Check plan limits with my Claude Code login", isOn: $liveUsage.enabled)
                Text("Off by default. When on, the app reads Claude Code's login from your Keychain and asks api.anthropic.com for your 5-hour and 7-day usage about every 5 minutes. The token stays in memory only: never written to disk, never logged. The endpoint is undocumented and may change.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Status") { Text(liveUsage.status).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
