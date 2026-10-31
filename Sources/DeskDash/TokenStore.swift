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
    /// How much of each subscription plan's limits is left (Claude via Claude Code's sign-in, ChatGPT via Codex).
    private(set) var limits: [AIProvider: [PlanLimit]] = [:]

    @ObservationIgnored private let logs = LocalUsageLogs()
    @ObservationIgnored private var localEvents: [UsageEvent] = []
    /// Use on Troy's other Macs, from their files in iCloud Drive.
    @ObservationIgnored private var otherMacEvents: [UsageEvent] = []
    @ObservationIgnored private var lastShare: Date = .distantPast
    /// The other Macs whose use is added in (empty: the counts are this Mac's only).
    private(set) var otherMacs: [String] = []

    /// How far the token counts reach: "on this Mac", or "on all your Macs" once another Mac shares its use.
    /// (Never the Claude app or website: those keep no counts on the Mac.)
    var countsScope: String { otherMacs.isEmpty ? "on this Mac" : "on all your Macs" }
    @ObservationIgnored private var accountEvents: [AIProvider: [UsageEvent]] = [:]
    @ObservationIgnored private var lastAccountFetch: Date = .distantPast
    @ObservationIgnored private var lastClaudeLimitsFetch: Date = .distantPast
    /// Read from the Keychain once and kept, so macOS doesn't ask over and over; read again when it stops working.
    @ObservationIgnored private var claudeToken: String?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var lastClaudeRenewal: Date = .distantPast

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

    /// Claude Code's sign-in, which carries the Claude plan's limits. Kept in the Keychain on a Mac.
    private static func claudeCodeToken() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let saved = Keychain.readData(service: "Claude Code-credentials") ?? (try? Data(contentsOf: file))
        return saved.flatMap { PlanLimits.claudeToken(fromCredentials: $0) }
    }

    /// Where the Claude Code program is, if it's on this Mac.
    private static func claudeProgram() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Claude Code's sign-in only lasts a few hours and renews itself when Claude Code runs. Asking Claude Code for
    /// its sign-in status ("claude auth status") renews it too, without asking Claude anything (no tokens used).
    /// At most every 10 minutes; the limits are read again right after.
    private func renewClaudeSignIn() {
        guard Date().timeIntervalSince(lastClaudeRenewal) > 600, let claude = Self.claudeProgram() else { return }
        lastClaudeRenewal = Date()
        Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = claude
            process.arguments = ["auth", "status"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            await MainActor.run {
                TokenStore.shared.claudeToken = nil
                TokenStore.shared.lastClaudeLimitsFetch = .distantPast
                TokenStore.shared.refresh()
            }
        }
    }

    /// "DeskDash Usage" in iCloud Drive: one file per Mac. Nil when iCloud Drive is off.
    private nonisolated static var sharedFolder: URL? {
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: iCloud.path) else { return nil }
        return iCloud.appendingPathComponent("DeskDash Usage")
    }

    private nonisolated static let macName = Host.current().localizedName ?? "Mac"

    /// Writes this Mac's use (when `write`) and reads the other Macs' (files changed in the last month).
    private nonisolated static func shareWithOtherMacs(_ local: [UsageEvent],
                                                       write: Bool) -> (events: [UsageEvent], macs: [String]) {
        guard let folder = sharedFolder else { return ([], []) }
        let manager = FileManager.default
        let mine = "usage-" + macName.replacingOccurrences(of: "/", with: "-") + ".json"
        if write {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = SharedUsageFile(mac: macName, events: local.filter { $0.source != .accountAPI })
            try? file.encoded().write(to: folder.appendingPathComponent(mine), options: .atomic)
        }
        var events: [UsageEvent] = []
        var macs: [String] = []
        for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            // iCloud may keep only a placeholder ("….json.icloud") until the file is downloaded.
            if name.hasSuffix(".icloud") {
                try? manager.startDownloadingUbiquitousItem(at: url)
                continue
            }
            guard name.hasPrefix("usage-"), name.hasSuffix(".json"), name != mine,
                  let data = try? Data(contentsOf: url), let file = SharedUsageFile.decode(data),
                  file.updated > Date().addingTimeInterval(-31 * 24 * 3600) else { continue }
            events += file.events
            macs.append(file.mac)
        }
        return (events, macs.sorted())
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
        // Claude's plan limits: every 2 minutes is plenty (it's the same check Claude Code's /usage does).
        var claudeToken: String?
        if Date().timeIntervalSince(lastClaudeLimitsFetch) > 120 {
            lastClaudeLimitsFetch = Date()
            if self.claudeToken == nil { self.claudeToken = Self.claudeCodeToken() }
            claudeToken = self.claudeToken
            if claudeToken == nil { renewClaudeSignIn() }
        }

        Task {
            let local = await Task.detached(priority: .utility) { logs.events() }.value
            localEvents = local
            let write = Date().timeIntervalSince(lastShare) > 120
            if write { lastShare = Date() }
            let shared = await Task.detached(priority: .utility) { Self.shareWithOtherMacs(local, write: write) }.value
            otherMacEvents = shared.events
            otherMacs = shared.macs
            limits[.openai] = await Task.detached(priority: .utility) { PlanLimits.latestCodex() }.value
            if let claudeToken {
                do {
                    limits[.anthropic] = try await PlanLimits.fetchClaude(token: claudeToken)
                } catch {
                    self.claudeToken = nil   // expired or renewed by Claude Code: read it again next time
                    renewClaudeSignIn()
                }
            }
            for (provider, key) in keys {
                do {
                    accountEvents[provider] = try await AccountUsage.fetch(provider, key: key)
                    problems[provider] = nil
                } catch {
                    problems[provider] = error.localizedDescription
                }
            }
            for provider in AIProvider.allCases where !hasKey(provider) { accountEvents[provider] = nil }
            usage = UsageSummary.summarize(localEvents + otherMacEvents + accountEvents.values.flatMap { $0 })
            updatedAt = Date()
            refreshing = false
        }
    }
}
