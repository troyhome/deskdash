import Foundation
import XCTest
@testable import DeskDashCore

final class ClassifierTests: XCTestCase {
    func testPathRulesWinOverExtensions() {
        XCTAssertEqual(Classifier.category(forPath: "/Applications/Xcode.app/Contents/Resources/icon.png"), .apps)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/.Trash/movie.mov"), .trash)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Library/Caches/com.apple.Safari/data.db"), .caches)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Library/Developer/Xcode/DerivedData/a/b.app/x"), .developer)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Library/Application Support/MobileSync/Backup/1/2"), .backups)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Pictures/Photos Library.photoslibrary/originals/1"), .photos)
    }

    func testExtensions() {
        XCTAssertEqual(Classifier.category(forPath: "/Volumes/Media/Trip.MOV"), .videos)
        XCTAssertEqual(Classifier.category(forPath: "/Volumes/2 Set Music/a.flac"), .music)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Downloads/Setup.dmg"), .archives)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Documents/Taxes.pdf"), .documents)
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/notes"), .other)
        // "Application Support" isn't an app bundle.
        XCTAssertEqual(Classifier.category(forPath: "/Users/troy/Library/Application Support/x.sqlite"), .other)
    }
}

final class ScannerTests: XCTestCase {
    func testScanAddsUpFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDashTest-\(UUID().uuidString)")
        let movies = root.appendingPathComponent("Movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 2_000_000).write(to: movies.appendingPathComponent("clip.mov"))
        try Data(count: 10_000).write(to: root.appendingPathComponent("readme.txt"))

        let result = DiskScanner.scan(roots: [root], isCancelled: { false })
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertGreaterThan(result.bytesByCategory[.videos] ?? 0, 1_900_000)
        XCTAssertEqual(result.largestByCategory[.videos]?.first?.name, "clip.mov")
        XCTAssertEqual(result.largestFolders().first?.path, root.standardizedFileURL.path + "/Movies")
    }

    func testTopListKeepsBiggest() {
        var list = TopList(limit: 3)
        for size in [5, 1, 9, 3, 7, 2, 8] {
            list.add(item("f\(size)", Int64(size)))
        }
        XCTAssertEqual(list.sorted().map(\.bytes), [9, 8, 7])
    }

    func testTopFolder() {
        XCTAssertEqual(DiskScanner.topFolder(of: "/Users/troy/Movies/a/b.mov", under: "/Users/troy"), "/Users/troy/Movies")
        XCTAssertEqual(DiskScanner.topFolder(of: "/Volumes/X/file", under: "/Volumes/X"), "/Volumes/X/file")
        XCTAssertNil(DiskScanner.topFolder(of: "/Other/file", under: "/Volumes/X"))
    }
}

final class SuggestionTests: XCTestCase {
    let gb = Bytes.gigabyte

    func testAlmostFullWithoutScan() {
        let tips = Suggestions.make(for: drive(total: 100 * gb, free: 5 * gb), scan: nil, otherDrives: [])
        XCTAssertEqual(tips.map(\.id), ["almost-full"])
    }

    func testCleanupAndMoveSuggestions() {
        let now = Date()
        var scan = ScanResult(roots: [])
        scan.bytesByCategory = [.trash: 2 * gb, .caches: 3 * gb, .videos: 6 * gb]
        scan.largestByCategory[.videos] = [item("/Users/troy/Movies/a.mov", 4 * gb), item("/Users/troy/Movies/b.mov", 2 * gb)]
        scan.largestByCategory[.archives] = [item("/Users/troy/Downloads/old.dmg", gb, modified: now.addingTimeInterval(-90 * 86400)),
                                             item("/Users/troy/Downloads/new.dmg", gb, modified: now)]
        let external = Drive(id: "/Volumes/Big", name: "Big", url: URL(fileURLWithPath: "/Volumes/Big"), kind: .external,
                             isBoot: false, isEjectable: true, totalBytes: 2000 * gb, availableBytes: 900 * gb)

        let tips = Suggestions.make(for: drive(total: 500 * gb, free: 200 * gb), scan: scan, otherDrives: [external], now: now)
        let ids = tips.map(\.id)
        XCTAssertEqual(ids.first, "videos") // biggest saving first
        XCTAssertTrue(ids.contains("trash"))
        XCTAssertTrue(ids.contains("caches"))
        XCTAssertEqual(tips.first { $0.id == "installers" }?.items.map(\.name), ["old.dmg"])
        XCTAssertEqual(tips.first?.title, "Move large videos to Big")
    }

    private func drive(total: Int64, free: Int64) -> Drive {
        Drive(id: "/", name: "Macintosh HD", url: URL(fileURLWithPath: "/"), kind: .internalDisk, isBoot: true,
              isEjectable: false, totalBytes: total, availableBytes: free)
    }
}

private func item(_ path: String, _ bytes: Int64, modified: Date? = nil) -> ScanItem {
    ScanItem(url: URL(fileURLWithPath: path), bytes: bytes, category: Classifier.category(forPath: path), modified: modified)
}

final class DriveListTests: XCTestCase {
    func testSharesOfOneNetworkDiskAreListedOnce() {
        func share(_ name: String, free: Int64, server: String = "crusher") -> Drive {
            Drive(id: "/Volumes/\(name)", name: name, url: URL(fileURLWithPath: "/Volumes/\(name)"), kind: .network,
                  isBoot: false, isEjectable: true, totalBytes: 10_000, availableBytes: free, server: server)
        }
        let merged = DriveList.mergingShares([share("PHOTOS", free: 1), share("music", free: 1),
                                              share("Movies Shows", free: 1), share("Backup", free: 5)])
        XCTAssertEqual(merged.map(\.name), ["crusher (Movies Shows, music, PHOTOS)", "Backup"])
    }
}

final class TokenUsageTests: XCTestCase {
    func testClaudeCodeKeepsLastCopyOfEachReply() {
        let log = """
        {"type":"user","message":{"role":"user","content":"hi"},"timestamp":"2026-10-29T10:00:00.000Z"}
        {"type":"assistant","requestId":"req_1","timestamp":"2026-10-29T10:00:01.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":5}}}
        {"type":"assistant","requestId":"req_1","timestamp":"2026-10-29T10:00:02.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":50,"cache_read_input_tokens":100,"cache_creation_input_tokens":5}}}
        {"type":"assistant","requestId":"req_2","timestamp":"2026-10-29T10:01:00Z","message":{"id":"msg_2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        """
        let events = LocalUsageLogs.claudeCodeEvents(in: Data(log.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.tokens, TokenCount(input: 10, output: 50, cacheRead: 100, cacheWrite: 5))
        XCTAssertEqual(events.first?.model, "claude-opus-5-5")
    }

    func testCodexSkipsRepeatedCounts() {
        let log = """
        {"timestamp":"2026-10-29T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-10-29T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120}}}}
        {"timestamp":"2026-10-29T10:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120}}}}
        {"timestamp":"2026-10-29T10:00:07Z","type":"event_msg","payload":{"type":"token_count","info":null}}
        """
        let events = LocalUsageLogs.codexEvents(in: Data(log.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.tokens, TokenCount(input: 60, output: 20, cacheRead: 40))
        XCTAssertEqual(events.first?.model, "gpt-5-codex")
    }

    func testGeminiChat() {
        let chat = """
        {"sessionId":"s","messages":[{"type":"user","timestamp":"2026-10-29T10:00:00Z","content":"hi"},
        {"type":"gemini","timestamp":"2026-10-29T10:00:03.120Z","model":"gemini-2.5-pro","tokens":{"input":200,"output":30,"cached":50,"thoughts":10,"tool":0,"total":240}}]}
        """
        let events = LocalUsageLogs.geminiEvents(in: Data(chat.utf8))
        XCTAssertEqual(events.first?.tokens, TokenCount(input: 150, output: 40, cacheRead: 50))
    }

    func testAntigravityTranscript() {
        let log = """
        {"step_index":0,"type":"USER_INPUT","created_at":"2026-10-19T00:22:36Z","content":"hi"}
        {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-10-19T00:22:36Z","input_tokens":15760,"cache_read_tokens":100,"output_tokens":145}
        """
        let events = LocalUsageLogs.antigravityEvents(in: Data(log.utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.tokens, TokenCount(input: 15760, output: 145, cacheRead: 100))
        XCTAssertEqual(events.first?.source, .antigravity)
    }

    func testAnthropicReport() {
        let report = """
        {"data":[{"starting_at":"2026-10-29T09:00:00Z","ending_at":"2026-10-29T10:00:00Z","results":[
        {"model":"claude-opus-5-5","uncached_input_tokens":1500,"cache_read_input_tokens":200,"output_tokens":500,
         "cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":5}}]}],"has_more":true,"next_page":"page_x"}
        """
        let parsed = AccountUsage.parse(.anthropic, Data(report.utf8))
        XCTAssertEqual(parsed?.nextPage, "page_x")
        XCTAssertEqual(parsed?.events.first?.tokens, TokenCount(input: 1500, output: 500, cacheRead: 200, cacheWrite: 15))
    }

    func testOpenAIReport() {
        let report = """
        {"object":"page","data":[{"object":"bucket","start_time":1793264400,"end_time":1793268000,"results":[
        {"object":"organization.usage.completions.result","input_tokens":1000,"input_cached_tokens":400,"output_tokens":90,"model":"gpt-5"}]}],
        "has_more":false,"next_page":null}
        """
        let parsed = AccountUsage.parse(.openai, Data(report.utf8))
        XCTAssertNil(parsed?.nextPage)
        XCTAssertEqual(parsed?.events.first?.tokens, TokenCount(input: 600, output: 90, cacheRead: 400))
        XCTAssertEqual(parsed?.events.first?.date, Date(timeIntervalSince1970: 1793264400))
    }

    func testSummaryBuckets() {
        let now = Date()
        func event(_ ago: TimeInterval, _ total: Int64, _ source: UsageSource = .claudeCode) -> UsageEvent {
            UsageEvent(provider: .anthropic, source: source, model: "claude-opus-5-5", date: now.addingTimeInterval(-ago),
                       tokens: TokenCount(output: total))
        }
        let usage = UsageSummary.summarize([event(60, 100), event(2 * 3600, 50), event(10 * 24 * 3600, 999)], now: now)
        let anthropic = usage.first { $0.provider == .anthropic }!
        XCTAssertEqual(anthropic.lastHour.total, 100)
        XCTAssertEqual(anthropic.hourly.last, 100)
        XCTAssertEqual(anthropic.hourly.reduce(0, +), 150)
        XCTAssertFalse(usage.first { $0.provider == .openai }!.hasData)
    }
}
