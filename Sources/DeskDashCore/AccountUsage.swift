import Foundation

/// Usage for a whole API account, from the provider's usage report. Needs an admin key (a normal API key can't
/// read usage). Reports run a few minutes behind.
///
/// - Anthropic: `GET /v1/organizations/usage_report/messages`, Admin API key (`sk-ant-admin...`) from the Claude
///   Console. Organizations only; individual accounts don't get admin keys.
/// - OpenAI: `GET /v1/organization/usage/completions`, Admin key from platform.openai.com.
/// - Google: no usage report for Gemini API keys (only through Google Cloud billing), so not offered here yet.
public enum AccountUsage {
    public enum Failure: Error, LocalizedError {
        case rejectedKey(AIProvider)
        case http(AIProvider, Int, String)
        case unreadable(AIProvider)

        public var errorDescription: String? {
            switch self {
            case .rejectedKey(let provider):
                "\(provider.title) didn't accept the key. It needs to be an admin key."
            case .http(let provider, let status, let message):
                "\(provider.title) answered \(status): \(message)"
            case .unreadable(let provider):
                "\(provider.title) sent a usage report DeskDash couldn't read."
            }
        }
    }

    /// Hourly usage for the last 7 days.
    public static func fetch(_ provider: AIProvider, key: String, now: Date = Date(),
                             session: URLSession = .shared) async throws -> [UsageEvent] {
        let since = Calendar.current.startOfDay(for: now.addingTimeInterval(-6 * 24 * 3600))
        var events: [UsageEvent] = []
        var page: String?
        for _ in 0..<10 {
            guard let request = request(provider, key: key, since: since, page: page) else { return [] }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { throw Failure.rejectedKey(provider) }
            guard status == 200 else {
                throw Failure.http(provider, status, String(decoding: data.prefix(300), as: UTF8.self))
            }
            guard let parsed = parse(provider, data) else { throw Failure.unreadable(provider) }
            events += parsed.events
            page = parsed.nextPage
            if page == nil { break }
        }
        return events
    }

    static func request(_ provider: AIProvider, key: String, since: Date, page: String?) -> URLRequest? {
        var components: URLComponents
        var request: URLRequest
        switch provider {
        case .anthropic:
            components = URLComponents(string: "https://api.anthropic.com/v1/organizations/usage_report/messages")!
            components.queryItems = [
                URLQueryItem(name: "starting_at", value: ISO8601DateFormatter().string(from: since)),
                URLQueryItem(name: "bucket_width", value: "1h"),
                URLQueryItem(name: "limit", value: "168"),
                URLQueryItem(name: "group_by[]", value: "model"),
            ]
            if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
            guard let url = components.url else { return nil }
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
            components.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(since.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1h"),
                URLQueryItem(name: "limit", value: "168"),
                URLQueryItem(name: "group_by", value: "model"),
            ]
            if let page { components.queryItems?.append(URLQueryItem(name: "page", value: page)) }
            guard let url = components.url else { return nil }
            request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .google:
            return nil
        }
        request.setValue("DeskDash/0.2", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    static func parse(_ provider: AIProvider, _ data: Data) -> (events: [UsageEvent], nextPage: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["data"] as? [[String: Any]] else { return nil }
        var events: [UsageEvent] = []
        for bucket in buckets {
            let start: Date?
            switch provider {
            case .openai: start = (bucket["start_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            default: start = (bucket["starting_at"] as? String).flatMap(LocalUsageLogs.parseDate)
            }
            guard let start, let results = bucket["results"] as? [[String: Any]] else { continue }
            for result in results {
                let tokens: TokenCount
                if provider == .openai {
                    let cached = LocalUsageLogs.int(result["input_cached_tokens"])
                    tokens = TokenCount(input: max(0, LocalUsageLogs.int(result["input_tokens"]) - cached),
                                        output: LocalUsageLogs.int(result["output_tokens"]), cacheRead: cached)
                } else {
                    let creation = result["cache_creation"] as? [String: Any]
                    tokens = TokenCount(input: LocalUsageLogs.int(result["uncached_input_tokens"]),
                                        output: LocalUsageLogs.int(result["output_tokens"]),
                                        cacheRead: LocalUsageLogs.int(result["cache_read_input_tokens"]),
                                        cacheWrite: LocalUsageLogs.int(creation?["ephemeral_5m_input_tokens"])
                                            + LocalUsageLogs.int(creation?["ephemeral_1h_input_tokens"]))
                }
                guard tokens.total > 0 else { continue }
                events.append(UsageEvent(provider: provider, source: .accountAPI,
                                         model: result["model"] as? String ?? provider.title,
                                         date: start, tokens: tokens))
            }
        }
        let more = root["has_more"] as? Bool ?? false
        return (events, more ? root["next_page"] as? String : nil)
    }
}
