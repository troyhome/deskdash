import Foundation

/// One mounted drive: the Mac's own disk, a USB/Thunderbolt drive, or a network share.
public struct Drive: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case internalDisk, external, network
    }

    /// The mount path, e.g. "/" or "/Volumes/Backup".
    public let id: String
    public let name: String
    public let url: URL
    public let kind: Kind
    public let isBoot: Bool
    public let isEjectable: Bool
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(id: String, name: String, url: URL, kind: Kind, isBoot: Bool, isEjectable: Bool,
                totalBytes: Int64, availableBytes: Int64) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.isBoot = isBoot
        self.isEjectable = isEjectable
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    /// Folders to look through when sorting the drive into categories. On the Mac's own disk only the parts the
    /// user owns (the rest is macOS itself and shows as "System & other").
    public var scanRoots: [URL] {
        guard isBoot else { return [url] }
        return [FileManager.default.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Applications", isDirectory: true)]
    }
}

public enum DriveList {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
    ]

    /// The drives mounted right now: the Mac's own disk first, then external drives, then network shares.
    public static func current() -> [Drive] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(drive(at:)).sorted(by: order)
    }

    static func drive(at url: URL) -> Drive? {
        let path = url.standardizedFileURL.path
        guard !path.hasPrefix("/System/Volumes"),
              let values = try? url.resourceValues(forKeys: Set(keys)),
              values.volumeIsBrowsable != false,
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let isBoot = values.volumeIsRootFileSystem ?? (path == "/")
        let kind: Drive.Kind
        if isBoot || values.volumeIsInternal == true {
            kind = .internalDisk
        } else if values.volumeIsLocal == false {
            kind = .network
        } else {
            kind = .external
        }
        // "Important usage" counts space macOS can free by itself (like Disk Utility does). Network shares don't
        // report it.
        let available = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
        return Drive(id: path, name: name, url: url, kind: kind, isBoot: isBoot,
                     isEjectable: values.volumeIsEjectable ?? false,
                     totalBytes: Int64(total), availableBytes: min(available, Int64(total)))
    }

    static func order(_ a: Drive, _ b: Drive) -> Bool {
        func rank(_ d: Drive) -> Int {
            if d.isBoot { return 0 }
            switch d.kind {
            case .internalDisk: return 1
            case .external: return 2
            case .network: return 3
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

public enum Bytes {
    /// "12.4 GB", the way Finder writes sizes.
    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static let gigabyte: Int64 = 1_000_000_000
    public static let megabyte: Int64 = 1_000_000
}
