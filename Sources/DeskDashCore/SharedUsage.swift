import Foundation

/// Token use shared between Troy's Macs through iCloud Drive, so each widget can add up all of them.
/// Each Mac writes one small file with its use per hour (from its own AI app logs) and reads the others'.
public struct SharedUsageFile: Codable, Sendable {
    public struct Bucket: Codable, Sendable {
        let provider: String
        let source: String
        let model: String
        /// The latest use within the hour, so "last hour" stays close to right.
        let date: Date
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        /// Missing in files written by DeskDash 0.6 and earlier.
        let webSearches: Int64?
    }

    public let mac: String
    public let updated: Date
    public let buckets: [Bucket]

    /// Adds `events` up per hour, provider, app and model.
    public init(mac: String, events: [UsageEvent], updated: Date = Date(), calendar: Calendar = .current) {
        struct Key: Hashable {
            let provider: AIProvider, source: UsageSource, model: String, hour: Date
        }
        var sums: [Key: (date: Date, tokens: TokenCount, searches: Int64)] = [:]
        for event in events {
            let hour = calendar.dateInterval(of: .hour, for: event.date)?.start ?? event.date
            let key = Key(provider: event.provider, source: event.source, model: event.model, hour: hour)
            let old = sums[key] ?? (event.date, TokenCount(), 0)
            sums[key] = (max(old.date, event.date), old.tokens + event.tokens, old.searches + event.webSearches)
        }
        self.mac = mac
        self.updated = updated
        buckets = sums.map { key, value in
            Bucket(provider: key.provider.rawValue, source: key.source.rawValue, model: key.model, date: value.date,
                   input: value.tokens.input, output: value.tokens.output, cacheRead: value.tokens.cacheRead,
                   cacheWrite: value.tokens.cacheWrite, webSearches: value.searches)
        }
        .sorted { $0.date < $1.date }
    }

    public var events: [UsageEvent] {
        buckets.compactMap { bucket in
            guard let provider = AIProvider(rawValue: bucket.provider),
                  let source = UsageSource(rawValue: bucket.source) else { return nil }
            return UsageEvent(provider: provider, source: source, model: bucket.model, date: bucket.date,
                              tokens: TokenCount(input: bucket.input, output: bucket.output,
                                                 cacheRead: bucket.cacheRead, cacheWrite: bucket.cacheWrite),
                              webSearches: bucket.webSearches ?? 0)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> SharedUsageFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedUsageFile.self, from: data)
    }
}
