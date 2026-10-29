import AppKit
import DeskDashCore
import SwiftUI

extension AIProvider {
    var color: Color {
        switch self {
        case .anthropic: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openai: Color(red: 0.06, green: 0.64, blue: 0.5)
        case .google: Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }

    /// Where usage comes from without any setup.
    var localTool: String {
        switch self {
        case .anthropic: "Claude Code"
        case .openai: "Codex"
        case .google: "Antigravity, Gemini CLI"
        }
    }
}

/// The AI token card in the widget and the menu bar.
struct AITokensCard: View {
    @Environment(TokenStore.self) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(tokens.usage) { usage in
                ProviderRow(usage: usage, limits: tokens.limits[usage.provider] ?? [],
                            problem: tokens.problems[usage.provider])
            }
        }
    }
}

struct ProviderRow: View {
    let usage: ProviderUsage
    let limits: [PlanLimit]
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(usage.provider.color).frame(width: 11, height: 11)
                Text(usage.provider.title).font(.title3.weight(.semibold))
                Spacer()
                if usage.hasData {
                    Text(TokenFormat.short(usage.today.total)).font(.title3.monospacedDigit().weight(.semibold))
                    Text("today").font(.callout).foregroundStyle(.secondary)
                } else if limits.isEmpty {
                    Text("No usage found").font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(limits) { limit in
                LimitBar(limit: limit)
            }
            if usage.hasData {
                HourlyBars(values: usage.hourly, color: usage.provider.color)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(tooltip)
    }

    private var detail: String {
        var parts = ["\(TokenFormat.short(usage.lastHour.total)) last hour",
                     "\(TokenFormat.short(usage.last7Days.total)) week",
                     "\(TokenFormat.short(usage.last30Days.total)) 30 days"]
        return parts.joined(separator: " · ")
    }

    private var tooltip: String {
        let sources = usage.todayBySource.sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue): \(TokenFormat.short($0.value)) today" }
        let models = usage.modelsToday.prefix(4).map { "\($0.model): \(TokenFormat.short($0.tokens))" }
        return (sources + models).joined(separator: "\n")
    }
}

/// "Session: 77% left, resets 4:10 PM", with a bar that fills as the limit gets used.
struct LimitBar: View {
    let limit: PlanLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name).font(.body)
                Text("\(Int(limit.leftPercent.rounded()))% left").font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                if let resets = limit.resetsAt {
                    Text("resets \(resetText(resets))").font(.callout).foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(100, max(0, limit.usedPercent)) / 100))
                }
            }
            .frame(height: 9)
        }
        .help("\(Int(limit.usedPercent.rounded()))% used")
    }

    private var color: Color {
        limit.usedPercent >= 90 ? .red : limit.usedPercent >= 70 ? .orange : .green
    }

    /// "4:10 PM" today, "Fri 9:00 AM" later.
    private func resetText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Tokens per hour for the last 24 hours, as small bars.
struct HourlyBars: View {
    let values: [Int64]
    let color: Color

    var body: some View {
        let biggest = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(values.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(values[index] > 0 ? color : Color.secondary.opacity(0.15))
                    .frame(height: max(2, 28 * CGFloat(Double(values[index]) / Double(biggest))))
            }
        }
        .frame(height: 28, alignment: .bottom)
        .help("Tokens per hour, last 24 hours")
    }
}

/// Paste admin keys for account-wide usage. Saved in the Keychain.
struct TokenSettingsView: View {
    @Environment(TokenStore.self) private var tokens
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var saved: AIProvider?

    var body: some View {
        Form {
            Section {
                Text("DeskDash already reads usage from Claude Code, Codex, Antigravity and Gemini CLI on this Mac, with no setup. "
                     + "To also see everything your API accounts use (other apps, scripts, teammates), paste an admin key below.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            keySection(.anthropic, key: $anthropicKey, prefix: "sk-ant-admin",
                       help: "Claude Console > Settings > Admin keys (platform.claude.com/settings/admin-keys). "
                           + "Only organization accounts have admin keys.")
            keySection(.openai, key: $openAIKey, prefix: "sk-admin",
                       help: "platform.openai.com > Settings > Organization > Admin keys.")
            Section("Google") {
                Text("Google has no usage report for Gemini API keys yet (only through Google Cloud billing), "
                     + "so DeskDash shows Antigravity and Gemini CLI usage from this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private func keySection(_ provider: AIProvider, key: Binding<String>, prefix: String, help: String) -> some View {
        Section(provider.title) {
            HStack {
                SecureField(tokens.hasKey(provider) ? "Key saved (paste a new one to replace it)" : "\(prefix)...",
                            text: key)
                Button("Save") {
                    tokens.saveKey(key.wrappedValue, for: provider)
                    key.wrappedValue = ""
                    saved = provider
                }
                .disabled(key.wrappedValue.isEmpty)
                if tokens.hasKey(provider) {
                    Button("Remove") { tokens.saveKey("", for: provider) }
                }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
            if saved == provider {
                Text("Saved in your Keychain. Usage shows up within a minute.").font(.caption).foregroundStyle(.green)
            }
            if let problem = tokens.problems[provider] {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

@MainActor
final class TokenSettingsWindowController {
    static let shared = TokenSettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AI Accounts"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TokenSettingsView().environment(TokenStore.shared))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
