import Foundation

/// Reads token usage from the logs AI coding tools keep on this Mac. No keys needed, and it's live: a reply shows
/// up seconds after it's written.
///
/// - Claude Code: `~/.claude/projects/**/*.jsonl` (also `~/.config/claude/projects`), one line per message, with
///   the reply's `usage`.
/// - Codex CLI: `~/.codex/sessions/**/rollout-*.jsonl`, `token_count` events.
/// - Gemini CLI: `~/.gemini/tmp/*/chats/session-*.json`, `tokens` on each Gemini message.
/// - Antigravity: `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`, one line per step.
///
/// Files are only re-read when they change.
public final class LocalUsageLogs: @unchecked Sendable {
    private let home: URL
    private let lock = NSLock()
    private var cache: [String: (size: Int, modified: Date, events: [UsageEvent])] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Every reply in the last `days` days. Slow the first time (reads every recent log), quick after.
    public func events(days: Int = 8, now: Date = Date()) -> [UsageEvent] {
        let since = now.addingTimeInterval(-Double(days) * 24 * 3600)
        var all: [UsageEvent] = []
        var seen = Set<String>()
        for folder in [".claude/projects", ".config/claude/projects"] {
            for file in files(under: home.appendingPathComponent(folder), suffix: ".jsonl", since: since) {
                all += cached(file) { Self.claudeCodeEvents(in: $0) }
            }
        }
        // A resumed Claude Code chat copies its earlier replies into the new log; count each reply once.
        all = all.filter { event in event.replyID.map { seen.insert($0).inserted } ?? true }
        for file in files(under: home.appendingPathComponent(".codex/sessions"), suffix: ".jsonl", since: since) {
            all += cached(file) { Self.codexEvents(in: $0) }
        }
        for file in files(under: home.appendingPathComponent(".gemini/tmp"), suffix: ".json", since: since)
        where file.path.contains("/chats/") {
            all += cached(file) { Self.geminiEvents(in: $0) }
        }
        // Antigravity's folders start with a dot, so they're looked up directly instead of walked.
        let brain = home.appendingPathComponent(".gemini/antigravity/brain")
        for chat in (try? FileManager.default.contentsOfDirectory(atPath: brain.path)) ?? [] {
            let file = brain.appendingPathComponent(chat).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified >= since else { continue }
            all += cached(file) { Self.antigravityEvents(in: $0) }
        }
        return all.filter { $0.date >= since }
    }

    private func files(under root: URL, suffix: String, since: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= since else { continue }
            found.append(url)
        }
        return found
    }

    private func cached(_ url: URL, parse: (Data) -> [UsageEvent]) -> [UsageEvent] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate ?? .distantPast
        lock.lock()
        if let hit = cache[url.path], hit.size == size, hit.modified == modified {
            lock.unlock()
            return hit.events
        }
        lock.unlock()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let events = parse(data)
        lock.lock()
        cache[url.path] = (size, modified, events)
        lock.unlock()
        return events
    }

    // MARK: Parsers

    static func claudeCodeEvents(in data: Data) -> [UsageEvent] {
        var events: [UsageEvent] = []
        var indexByReply: [String: Int] = [:]
        forEachJSONLine(in: data, containing: "\"usage\"") { line in
            guard let message = line["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let date = (line["timestamp"] as? String).flatMap(parseDate) else { return }
            let model = message["model"] as? String ?? "claude"
            if model == "<synthetic>" { return }
            let replyID = (message["id"] as? String).map { $0 + "|" + (line["requestId"] as? String ?? "") }
            let tokens = TokenCount(input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                                    cacheRead: int(usage["cache_read_input_tokens"]),
                                    cacheWrite: int(usage["cache_creation_input_tokens"]))
            guard tokens.total > 0 else { return }
            let event = UsageEvent(provider: .anthropic, source: .claudeCode, model: model, date: date,
                                   tokens: tokens, replyID: replyID)
            // Streaming writes a reply several times as it grows; the last copy has the final count.
            if let replyID, let index = indexByReply[replyID] {
                events[index] = event
            } else {
                if let replyID { indexByReply[replyID] = events.count }
                events.append(event)
            }
        }
        return events
    }

    static func codexEvents(in data: Data) -> [UsageEvent] {
        var events: [UsageEvent] = []
        var model = "gpt"
        var lastTotal: Int64 = -1
        forEachJSONLine(in: data, containing: nil) { line in
            guard let payload = line["payload"] as? [String: Any] else { return }
            if let name = payload["model"] as? String { model = name }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let date = (line["timestamp"] as? String).flatMap(parseDate) else { return }
            // The same count is sometimes repeated; the running total shows whether anything new happened.
            let total = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if total == lastTotal { return }
            lastTotal = total
            let cached = int(last["cached_input_tokens"])
            let tokens = TokenCount(input: max(0, int(last["input_tokens"]) - cached),
                                    output: int(last["output_tokens"]), cacheRead: cached)
            guard tokens.total > 0 else { return }
            events.append(UsageEvent(provider: .openai, source: .codex, model: model, date: date, tokens: tokens))
        }
        return events
    }

    static func geminiEvents(in data: Data) -> [UsageEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { message in
            guard let tokens = message["tokens"] as? [String: Any],
                  let date = (message["timestamp"] as? String).flatMap(parseDate) else { return nil }
            let cached = int(tokens["cached"])
            let count = TokenCount(input: max(0, int(tokens["input"]) - cached),
                                   output: int(tokens["output"]) + int(tokens["thoughts"]), cacheRead: cached)
            guard count.total > 0 else { return nil }
            return UsageEvent(provider: .google, source: .geminiCLI, model: message["model"] as? String ?? "gemini",
                              date: date, tokens: count)
        }
    }

    static func antigravityEvents(in data: Data) -> [UsageEvent] {
        var events: [UsageEvent] = []
        forEachJSONLine(in: data, containing: "\"output_tokens\"") { line in
            guard let date = (line["created_at"] as? String).flatMap(parseDate) else { return }
            let tokens = TokenCount(input: int(line["input_tokens"]), output: int(line["output_tokens"]),
                                    cacheRead: int(line["cache_read_tokens"]))
            guard tokens.total > 0 else { return }
            events.append(UsageEvent(provider: .google, source: .antigravity,
                                     model: line["model"] as? String ?? "gemini", date: date, tokens: tokens))
        }
        return events
    }

    // MARK: Helpers

    /// Calls `body` with each line that parses as a JSON object. `containing` skips lines without that text
    /// before parsing them (logs are big, most lines aren't replies).
    static func forEachJSONLine(in data: Data, containing needle: String?, _ body: ([String: Any]) -> Void) {
        let needleBytes = needle.map { Data($0.utf8) }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            if line.isEmpty { continue }
            if let needleBytes, line.range(of: needleBytes) == nil { continue }
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                body(object)
            }
        }
    }

    static func int(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber: number.int64Value
        case let string as String: Int64(string) ?? 0
        default: 0
        }
    }

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let withoutFraction = ISO8601DateFormatter()

    static func parseDate(_ text: String) -> Date? {
        withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }
}
