import DeskDashCore
import Foundation

/// Tells a running scan to stop. Checked by the scan's workers, which run outside Swift's tasks.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func set() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

/// Finished scans saved on this Mac (Application Support/DeskDash/Scans), so a long scan of a big drive isn't lost
/// when DeskDash quits or is updated.
enum ScanArchive {
    private struct Saved: Codable {
        let driveID: String
        let result: ScanResult
    }

    private static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeskDash/Scans")
    }

    private static func file(for driveID: String) -> URL {
        let name = driveID.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent((name.isEmpty ? "root" : name) + ".json")
    }

    static func save(_ result: ScanResult, for driveID: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Saved(driveID: driveID, result: result)) {
            try? data.write(to: file(for: driveID), options: .atomic)
        }
    }

    static func loadAll() -> [String: ScanResult] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var scans: [String: ScanResult] = [:]
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let saved = try? decoder.decode(Saved.self, from: data) {
                scans[saved.driveID] = saved.result
            }
        }
        return scans
    }
}
