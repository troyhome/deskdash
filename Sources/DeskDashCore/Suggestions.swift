import Foundation

/// A tip for freeing space or keeping data safe, with the files it's about.
public struct Suggestion: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case delete = "Delete"
        case consolidate = "Move"
        case backUp = "Back up"
        case review = "Review"
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    /// Space it could free (0 when it's not about freeing space).
    public let bytes: Int64
    public let items: [ScanItem]

    public init(id: String, kind: Kind, title: String, detail: String, bytes: Int64 = 0, items: [ScanItem] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.bytes = bytes
        self.items = items
    }
}

public enum Suggestions {
    /// Tips for `drive`, biggest savings first. Without a scan only the "almost full" warning can show.
    public static func make(for drive: Drive, scan: ScanResult?, otherDrives: [Drive],
                            now: Date = Date()) -> [Suggestion] {
        let gb = Bytes.gigabyte
        var warnings: [Suggestion] = []
        if drive.usedFraction >= 0.9 {
            warnings.append(Suggestion(
                id: "almost-full", kind: .review, title: "\(drive.name) is almost full",
                detail: "Only \(Bytes.format(drive.availableBytes)) left. "
                    + "A drive this full gets slow, and macOS updates can fail."))
        }
        guard let scan else { return warnings }

        func bytes(_ category: StorageCategory) -> Int64 { scan.bytesByCategory[category] ?? 0 }
        func items(_ category: StorageCategory) -> [ScanItem] { scan.largestByCategory[category] ?? [] }
        var tips: [Suggestion] = []

        if bytes(.trash) >= gb / 2 {
            tips.append(Suggestion(
                id: "trash", kind: .delete, title: "Empty the Trash",
                detail: "Files in the Trash still take up space until you empty it.",
                bytes: bytes(.trash), items: items(.trash)))
        }
        if bytes(.caches) >= gb {
            tips.append(Suggestion(
                id: "caches", kind: .delete, title: "Clear app caches and logs",
                detail: "Apps make these again when they need them. Quit an app before deleting its cache.",
                bytes: bytes(.caches), items: items(.caches)))
        }
        if bytes(.developer) >= 5 * gb {
            tips.append(Suggestion(
                id: "developer", kind: .delete, title: "Clean up developer build files",
                detail: "Xcode build folders, simulators and downloaded code packages can be rebuilt.",
                bytes: bytes(.developer), items: items(.developer)))
        }

        let monthAgo = now.addingTimeInterval(-30 * 24 * 3600)
        let installers = items(.archives).filter {
            $0.url.path.contains("/Downloads/") && ($0.modified.map { $0 < monthAgo } ?? false)
        }
        let installerBytes = installers.reduce(0) { $0 + $1.bytes }
        if installerBytes >= 200 * Bytes.megabyte {
            tips.append(Suggestion(
                id: "installers", kind: .delete, title: "Remove old installers and archives in Downloads",
                detail: "Disk images and zip files you downloaded over a month ago are usually already installed or unpacked.",
                bytes: installerBytes, items: installers))
        }

        if bytes(.backups) >= 5 * gb {
            tips.append(Suggestion(
                id: "device-backups", kind: .review, title: "Check old iPhone and iPad backups",
                detail: "Delete backups of devices you no longer use, in Finder or System Settings > General > Storage.",
                bytes: bytes(.backups), items: items(.backups)))
        }

        let bigVideos = items(.videos).filter { $0.bytes >= gb }
        let bigVideoBytes = bigVideos.reduce(0) { $0 + $1.bytes }
        if drive.kind == .internalDisk, bigVideoBytes >= 2 * gb {
            let target = otherDrives.filter { $0.kind != .internalDisk && $0.availableBytes > bigVideoBytes }
                .max { $0.availableBytes < $1.availableBytes }
            tips.append(Suggestion(
                id: "videos", kind: .consolidate,
                title: "Move large videos to \(target?.name ?? "an external drive")",
                detail: target.map { "It has \(Bytes.format($0.availableBytes)) free, enough for all of them." }
                    ?? "Connect an external or network drive with enough free space.",
                bytes: bigVideoBytes, items: bigVideos))
        }

        if scan.oldBytes >= 2 * gb {
            tips.append(Suggestion(
                id: "old-files", kind: .consolidate, title: "Archive files you haven't changed in a year",
                detail: "Moving them to an external or network drive frees space here and keeps them handy.",
                bytes: scan.oldBytes, items: scan.oldFiles))
        }

        let irreplaceable = bytes(.photos) + bytes(.videos) + bytes(.documents)
        if drive.kind != .network, irreplaceable >= 10 * gb {
            tips.append(Suggestion(
                id: "backup", kind: .backUp, title: "Keep a second copy of your photos, videos and documents",
                detail: drive.isBoot
                    ? "\(Bytes.format(irreplaceable)) of them live here. Time Machine to an external drive is the easiest way."
                    : "\(Bytes.format(irreplaceable)) of them live here. Drives can fail without warning, so copy them to another drive or a network share."))
        }

        return warnings + tips.sorted { $0.bytes > $1.bytes }
    }
}
