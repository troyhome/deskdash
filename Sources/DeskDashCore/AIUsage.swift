import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Hashable, Sendable {
    case anthropic, openai, google

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .google: "Google"
        }
    }
}

/// Where a usage number came from.
public enum UsageSource: String, Hashable, Sendable {
    /// Claude Code's own logs on this Mac.
    case claudeCode = "Claude Code"
    /// Codex CLI's logs on this Mac.
    case codex = "Codex"
    /// Gemini CLI's logs on this Mac.
    case geminiCLI = "Gemini CLI"
    /// The provider's usage report for the whole account (needs an admin key).
    case accountAPI = "API account"
}

public struct TokenCount: Hashable, Sendable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int64 { input + output + cacheRead + cacheWrite }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    public static func += (a: inout TokenCount, b: TokenCount) { a = a + b }
}

/// Tokens used at one moment (one reply, or one bucket of an account report).
public struct UsageEvent: Hashable, Sendable {
    public let provider: AIProvider
    public let source: UsageSource
    public let model: String
    public let date: Date
    public let tokens: TokenCount
    /// Identifies one reply, to count it once when it appears in several logs.
    public let replyID: String?

    public init(provider: AIProvider, source: UsageSource, model: String, date: Date, tokens: TokenCount,
                replyID: String? = nil) {
        self.provider = provider
        self.source = source
        self.model = model
        self.date = date
        self.tokens = tokens
        self.replyID = replyID
    }
}

/// What the widget shows for one provider.
public struct ProviderUsage: Identifiable, Hashable, Sendable {
    public var id: AIProvider { provider }
    public let provider: AIProvider
    public var lastHour = TokenCount()
    public var today = TokenCount()
    public var last7Days = TokenCount()
    /// Tokens per hour for the last 24 hours, oldest first.
    public var hourly: [Int64] = Array(repeating: 0, count: 24)
    /// Today's tokens by model, biggest first.
    public var modelsToday: [(model: String, tokens: Int64)] = []
    public var sources: Set<UsageSource> = []
    public var todayBySource: [UsageSource: Int64] = [:]

    public init(provider: AIProvider) {
        self.provider = provider
    }

    public static func == (a: ProviderUsage, b: ProviderUsage) -> Bool {
        a.provider == b.provider && a.lastHour == b.lastHour && a.today == b.today && a.last7Days == b.last7Days
            && a.hourly == b.hourly && a.sources == b.sources
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(provider)
        hasher.combine(today)
    }

    public var hasData: Bool { !sources.isEmpty }
}

public enum UsageSummary {
    /// Adds events up per provider, keeping each source's share of today. (Claude Code on a subscription doesn't show
    /// up in the account report, so the sources are added together and listed separately; if Claude Code runs on
    /// an API key, the breakdown shows the overlap.)
    public static func summarize(_ events: [UsageEvent], now: Date = Date(),
                                 calendar: Calendar = .current) -> [ProviderUsage] {
        let startOfToday = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let hourAgo = now.addingTimeInterval(-3600)
        let dayAgo = now.addingTimeInterval(-24 * 3600)

        return AIProvider.allCases.map { provider in
            let mine = events.filter { $0.provider == provider }
            var usage = ProviderUsage(provider: provider)
            var models: [String: Int64] = [:]
            for event in mine {
                usage.sources.insert(event.source)
                if event.date >= hourAgo { usage.lastHour += event.tokens }
                if event.date >= weekAgo { usage.last7Days += event.tokens }
                if event.date >= startOfToday {
                    usage.today += event.tokens
                    models[event.model, default: 0] += event.tokens.total
                    usage.todayBySource[event.source, default: 0] += event.tokens.total
                }
                if event.date >= dayAgo, event.date <= now {
                    let slot = 23 - min(23, Int(now.timeIntervalSince(event.date) / 3600))
                    usage.hourly[slot] += event.tokens.total
                }
            }
            usage.modelsToday = models.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            return usage
        }
    }
}

public enum TokenFormat {
    /// "1.2M", "45K", "820".
    public static func short(_ tokens: Int64) -> String {
        let value = Double(tokens)
        switch tokens {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1e9)
        case 1_000_000...: return String(format: "%.1fM", value / 1e6)
        case 10_000...: return String(format: "%.0fK", value / 1e3)
        case 1_000...: return String(format: "%.1fK", value / 1e3)
        default: return "\(tokens)"
        }
    }
}
