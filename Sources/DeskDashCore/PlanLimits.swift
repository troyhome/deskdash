import Foundation

/// One usage limit of a subscription plan, like Claude's 5-hour session or ChatGPT's weekly limit.
public struct PlanLimit: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// 0-100.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var leftPercent: Double { max(0, 100 - usedPercent) }
}

/// How much of the Claude and ChatGPT plans' limits is left. These aren't official, documented APIs (they're what
/// Claude Code's /usage screen and Codex's status line use), so they may change; DeskDash then just shows nothing.
///
/// - Claude (Pro/Max): `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's sign-in token.
/// - ChatGPT (Plus/Pro, via Codex): the `rate_limits` Codex writes into its session logs after every reply.
public enum PlanLimits {
    // MARK: Claude

    static let claudeNames: [(key: String, name: String)] = [
        ("five_hour", "Session"),
        ("seven_day", "Week"),
        ("seven_day_opus", "Week (Opus)"),
        ("seven_day_sonnet", "Week (Sonnet)"),
    ]

    public static func fetchClaude(token: String, session: URLSession = .shared) async throws -> [PlanLimit] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("DeskDash/0.2", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw AccountUsage.Failure.rejectedKey(.anthropic) }
        guard status == 200 else {
            throw AccountUsage.Failure.http(.anthropic, status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return parseClaude(data)
    }

    static func parseClaude(_ data: Data) -> [PlanLimit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return claudeNames.compactMap { key, name in
            guard let window = root[key] as? [String: Any], let used = window["utilization"] as? NSNumber
            else { return nil }
            return PlanLimit(name: name, usedPercent: used.doubleValue,
                             resetsAt: (window["resets_at"] as? String).flatMap(parseClaudeDate))
        }
    }

    /// "2026-10-29T15:00:00.034642+00:00" (microseconds, which ISO8601DateFormatter doesn't read).
    static func parseClaudeDate(_ text: String) -> Date? {
        if let date = LocalUsageLogs.parseDate(text) { return date }
        guard let dot = text.firstIndex(of: "."),
              let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let whole = String(text[..<dot])
        let fraction = String(text[text.index(after: dot)..<zone].prefix(3))
        return LocalUsageLogs.parseDate(whole + "." + fraction + String(text[zone...]))
    }

    /// Claude Code's sign-in token, from the JSON it saves (Keychain item "Claude Code-credentials", or
    /// ~/.claude/.credentials.json). Nil when it has expired: Claude Code renews it the next time it runs.
    public static func claudeToken(fromCredentials data: Data, now: Date = Date()) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = oauth["expiresAt"] as? NSNumber,
           Date(timeIntervalSince1970: expires.doubleValue / 1000) < now { return nil }
        return token
    }

    // MARK: Codex

    /// The newest limits Codex wrote, across its recent session logs.
    public static func latestCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [PlanLimit] {
        let root = home.appendingPathComponent(".codex/sessions")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var newest: (url: URL, date: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        guard let newest, let data = try? Data(contentsOf: newest.url, options: .mappedIfSafe) else { return [] }
        return parseCodex(data)
    }

    static func parseCodex(_ data: Data) -> [PlanLimit] {
        var latest: [PlanLimit] = []
        LocalUsageLogs.forEachJSONLine(in: data, containing: "\"rate_limits\"") { line in
            guard let payload = line["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { return }
            let stamp = (line["timestamp"] as? String).flatMap(LocalUsageLogs.parseDate) ?? Date()
            let found: [PlanLimit] = ["primary", "secondary"].compactMap { key in
                guard let window = limits[key] as? [String: Any],
                      let used = window["used_percent"] as? NSNumber else { return nil }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
                let resets: Date?
                if let at = window["resets_at"] as? NSNumber {
                    resets = Date(timeIntervalSince1970: at.doubleValue)
                } else if let seconds = window["resets_in_seconds"] as? NSNumber {
                    resets = stamp.addingTimeInterval(seconds.doubleValue)
                } else {
                    resets = nil
                }
                let name = minutes >= 24 * 60 ? "Week" : minutes > 0 ? "Session" : (key == "primary" ? "Session" : "Week")
                return PlanLimit(name: name, usedPercent: used.doubleValue, resetsAt: resets)
            }
            if !found.isEmpty { latest = found }
        }
        // A limit whose reset time has passed has started over.
        return latest.map { limit in
            if let resets = limit.resetsAt, resets < Date() {
                return PlanLimit(name: limit.name, usedPercent: 0, resetsAt: nil)
            }
            return limit
        }
    }
}
