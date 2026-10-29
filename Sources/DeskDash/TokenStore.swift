import DeskDashCore
import Foundation
import Observation

/// Live AI token usage: local tool logs every 20 seconds, account reports every 5 minutes.
@MainActor @Observable
final class TokenStore {
    static let shared = TokenStore()

    private(set) var usage: [ProviderUsage] = AIProvider.allCases.map { ProviderUsage(provider: $0) }
    /// Problems reading an account report, per provider, in plain words.
    private(set) var problems: [AIProvider: String] = [:]
    private(set) var updatedAt: Date?

    @ObservationIgnored private let logs = LocalUsageLogs()
    @ObservationIgnored private var localEvents: [UsageEvent] = []
    @ObservationIgnored private var accountEvents: [AIProvider: [UsageEvent]] = [:]
    @ObservationIgnored private var lastAccountFetch: Date = .distantPast
    @ObservationIgnored private var refreshing = false

    private init() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in TokenStore.shared.refresh() }
        }
    }

    static func keyAccount(_ provider: AIProvider) -> String { "admin-key-\(provider.rawValue)" }

    func hasKey(_ provider: AIProvider) -> Bool {
        !(Keychain.read(Self.keyAccount(provider)) ?? "").isEmpty
    }

    func saveKey(_ key: String, for provider: AIProvider) {
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keyAccount(provider))
        accountEvents[provider] = nil
        problems[provider] = nil
        lastAccountFetch = .distantPast
        refresh()
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let logs = self.logs
        let fetchAccounts = Date().timeIntervalSince(lastAccountFetch) > 300
        let keys: [AIProvider: String] = fetchAccounts
            ? Dictionary(uniqueKeysWithValues: [AIProvider.anthropic, .openai].compactMap { provider in
                Keychain.read(Self.keyAccount(provider)).flatMap { $0.isEmpty ? nil : (provider, $0) }
            })
            : [:]
        if fetchAccounts { lastAccountFetch = Date() }

        Task {
            let local = await Task.detached(priority: .utility) { logs.events() }.value
            localEvents = local
            for (provider, key) in keys {
                do {
                    accountEvents[provider] = try await AccountUsage.fetch(provider, key: key)
                    problems[provider] = nil
                } catch {
                    problems[provider] = error.localizedDescription
                }
            }
            for provider in AIProvider.allCases where !hasKey(provider) { accountEvents[provider] = nil }
            usage = UsageSummary.summarize(localEvents + accountEvents.values.flatMap { $0 })
            updatedAt = Date()
            refreshing = false
        }
    }
}
