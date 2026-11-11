import AppKit
import SwiftUI

/// The panel under the menu-bar item: live sessions, background tasks, plan limits, usage by project.
struct PanelView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.hooks.hooks && !model.isDemo { setupCallout }
            SessionsSection(sessions: model.sessions)
            if !model.agents.isEmpty { AgentsSection(agents: model.agents) }
            if let limits = model.limits, limits.fiveHour != nil || limits.sevenDay != nil {
                LimitsSection(limits: limits)
            }
            UsageSection(usage: model.usage)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: StatusIcon.color(model.overall))).frame(width: 9, height: 9)
            Text(AppSupport.name).font(.headline)
            Spacer()
            Text(StatusIcon.tooltip(model.overall)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var setupCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hooks aren't installed").font(.subheadline.weight(.semibold))
            Text("Live sessions and plan limits come from Claude Code hooks. Install them in Settings; usage by project works without them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…", action: openSettings).controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

// MARK: - Sections

private struct SectionTitle: View {
    let text: String
    var trailing: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

private struct SessionsSection: View {
    let sessions: [ClaudeSessionInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Live sessions")
            if sessions.isEmpty {
                Text("No Claude Code session right now").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in SessionRow(session: session) }
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSessionInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Self.color(session.state)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project).font(.body.weight(.semibold)).lineLimit(1)
                    Text(Self.label(session.state)).font(.caption.weight(.medium)).foregroundStyle(Self.color(session.state))
                }
                Text(session.activity).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                let details = [ToolText.prettyModel(session.model), session.contextPercent.map { "context \($0)%" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button("Open ›") { SessionOpener.open(cwd: session.cwd) }
                .buttonStyle(.borderless).font(.callout)
                .help("Bring this session's window forward")
        }
    }

    static func label(_ state: ClaudeStatus.State) -> String {
        switch state {
        case .working: "Working"
        case .waiting: "Needs you"
        case .done: "Done"
        case .error: "Failed"
        case .idle: "Idle"
        }
    }

    static func color(_ state: ClaudeStatus.State) -> Color {
        switch state {
        case .working: .yellow
        case .waiting: .red
        case .done: .green
        case .error: .orange
        case .idle: .gray
        }
    }
}

private struct AgentsSection: View {
    let agents: [SubagentInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Background tasks")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(agent.name).font(.callout.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(Format.elapsed(context.date.timeIntervalSince(agent.startedAt)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text("\(agent.current) · \(agent.toolUses) \(agent.toolUses == 1 ? "tool" : "tools")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

private struct LimitsSection: View {
    let limits: PlanLimits
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Plan limits", trailing: limits.source == .live ? "Live usage" : "from Claude Code")
            if let window = limits.fiveHour { LimitBar(title: "5-hour", window: window) }
            if let window = limits.sevenDay { LimitBar(title: "7-day", window: window) }
        }
    }
}

private struct LimitBar: View {
    let title: String
    let window: LimitWindow

    var body: some View {
        let expired = window.isExpired()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(expired ? "reset" : "\(Int(window.percent.rounded()))%")
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(barColor)
                        .frame(width: geometry.size.width * (expired ? 0 : window.percent / 100))
                }
            }
            .frame(height: 6)
            if let resetsAt = window.resetsAt {
                Text(expired ? "Window reset; waiting for new data" : Format.resets(Date(timeIntervalSince1970: resetsAt)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(expired ? 0.6 : 1)
    }

    private var barColor: Color {
        window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .blue
    }
}

private struct UsageSection: View {
    let usage: ProjectUsageSummary?
    @State private var period = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Usage by project")
            Picker("", selection: $period) {
                Text("Today").tag(0)
                Text("7 days").tag(1)
                Text("30 days").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let usage {
                let data = [usage.today, usage.week, usage.month][period]
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.tokens(data.tokens) + " tokens").font(.callout.weight(.semibold))
                    Spacer()
                    Text("≈ " + Format.cost(data.cost) + " estimate").font(.callout.monospacedDigit())
                }
                if data.rows.isEmpty {
                    Text("No usage in this period").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(data.rows.prefix(8)) { row in
                    HStack {
                        Text(row.project).font(.callout).lineLimit(1)
                        Spacer()
                        Text(Format.tokens(row.tokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(Format.cost(row.cost)).font(.callout.monospacedDigit()).frame(minWidth: 62, alignment: .trailing)
                    }
                }
                Text("Estimate at API list prices from local transcripts; not what your plan costs."
                     + (usage.unpriced ? " Some models have no known price and add nothing." : ""))
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reading local transcripts…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Number and time formatting. Pure, unit-tested.
enum Format {
    static func tokens(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    static func cost(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func resets(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 24 * 3600 {
            let h = seconds / 3600, m = (seconds % 3600) / 60
            return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
        }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
