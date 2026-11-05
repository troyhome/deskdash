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
    /// Google Antigravity's logs on this Mac.
    case antigravity = "Antigravity"
    /// The provider's usage report for the whole account (needs an admin key).
    case accountAPI = "API account"
    /// Troy's own apps (Even Quicker and others) that log each API reply they get.
    case apps = "Your apps"
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
    /// Web searches Claude ran for this reply (billed per search on an API key).
    public let webSearches: Int64

    public init(provider: AIProvider, source: UsageSource, model: String, date: Date, tokens: TokenCount,
                replyID: String? = nil, webSearches: Int64 = 0) {
        self.provider = provider
        self.source = source
        self.model = model
        self.date = date
        self.tokens = tokens
        self.replyID = replyID
        self.webSearches = webSearches
    }
}

/// What the widget shows for one provider.
public struct ProviderUsage: Identifiable, Hashable, Sendable {
    public var id: AIProvider { provider }
    public let provider: AIProvider
    public var lastHour = TokenCount()
    public var today = TokenCount()
    public var last7Days = TokenCount()
    public var last30Days = TokenCount()
    /// Tokens per hour for the last 24 hours, oldest first.
    public var hourly: [Int64] = Array(repeating: 0, count: 24)
    /// Today's tokens by model, biggest first.
    public var modelsToday: [(model: String, tokens: Int64)] = []
    public var sources: Set<UsageSource> = []
    public var todayBySource: [UsageSource: Int64] = [:]
    /// Web searches made with an API key (apps and the account report). Claude Code's searches are part of its
    /// plan, so they aren't counted here.
    public var searchesToday: Int64 = 0
    public var searches30Days: Int64 = 0
    /// Estimated charge (US dollars) for API-key use: tokens at list price plus web searches.
    /// Plan use (Claude Code, Codex, Gemini CLI) isn't charged per token, so it isn't in here.
    public var apiCostToday: Double = 0
    public var apiCost30Days: Double = 0

    public init(provider: AIProvider) {
        self.provider = provider
    }

    public static func == (a: ProviderUsage, b: ProviderUsage) -> Bool {
        a.provider == b.provider && a.lastHour == b.lastHour && a.today == b.today && a.last7Days == b.last7Days
            && a.last30Days == b.last30Days
            && a.hourly == b.hourly && a.sources == b.sources
            && a.searchesToday == b.searchesToday && a.searches30Days == b.searches30Days
            && a.apiCostToday == b.apiCostToday && a.apiCost30Days == b.apiCost30Days
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
        let monthAgo = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        let hourAgo = now.addingTimeInterval(-3600)
        let dayAgo = now.addingTimeInterval(-24 * 3600)

        return AIProvider.allCases.map { provider in
            let mine = events.filter { $0.provider == provider }
            var usage = ProviderUsage(provider: provider)
            var models: [String: Int64] = [:]
            for event in mine {
                usage.sources.insert(event.source)
                if event.date >= hourAgo { usage.lastHour += event.tokens }
                if event.date >= monthAgo { usage.last30Days += event.tokens }
                if event.source == .apps || event.source == .accountAPI {
                    let cost = APIPrice.dollars(event)
                    if event.date >= monthAgo {
                        usage.searches30Days += event.webSearches
                        usage.apiCost30Days += cost
                    }
                    if event.date >= startOfToday {
                        usage.searchesToday += event.webSearches
                        usage.apiCostToday += cost
                    }
                }
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

/// What web searches cost on an API key: $10 per 1,000 searches (Anthropic's list price), on top of tokens.
public enum WebSearchPrice {
    public static let dollarsPerSearch = 0.01

    public static func dollars(_ searches: Int64) -> Double { Double(searches) * dollarsPerSearch }

    /// "$0.41", or "$1,204.50".
    public static func text(_ searches: Int64) -> String {
        dollars(searches).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

/// Anthropic API list prices per million tokens (US dollars), checked November 2026. Used for an estimate only;
/// the real bill is in the Claude Console. OpenAI and Google use aren't priced yet (their cost stays 0).
public enum APIPrice {
    public struct Rates: Sendable, Equatable {
        public let input, output, cacheRead, cacheWrite: Double
    }

    /// Nil when the model isn't one DeskDash knows a price for.
    public static func rates(for model: String) -> Rates? {
        let m = model.lowercased()
        guard m.contains("claude") || m.contains("fable") || m.contains("mythos") || m.contains("opus")
                || m.contains("sonnet") || m.contains("haiku") else { return nil }
        if m.contains("fable") || m.contains("mythos") { return Rates(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5) }
        if m.contains("opus-5-5") { return Rates(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5) }
        if m.contains("opus") { return Rates(input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25) }
        if m.contains("sonnet-4") { return Rates(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75) }
        if m.contains("sonnet") { return Rates(input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5) }
        if m.contains("haiku-4") { return Rates(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25) }
        if m.contains("haiku") { return Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125) }
        return Rates(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)
    }

    /// Tokens at list price plus web searches. Cache writes are priced at the 5-minute rate.
    public static func dollars(_ event: UsageEvent) -> Double {
        var total = WebSearchPrice.dollars(event.webSearches)
        if event.provider == .anthropic, let r = rates(for: event.model) {
            let t = event.tokens
            total += (Double(t.input) * r.input + Double(t.output) * r.output
                + Double(t.cacheRead) * r.cacheRead + Double(t.cacheWrite) * r.cacheWrite) / 1_000_000
        }
        return total
    }

    /// "$1.23", or "under $0.01".
    public static func text(_ dollars: Double) -> String {
        if dollars > 0, dollars < 0.01 { return "under $0.01" }
        return dollars.formatted(.currency(code: "USD").precision(.fractionLength(2)))
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
