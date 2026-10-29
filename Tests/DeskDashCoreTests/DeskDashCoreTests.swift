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
