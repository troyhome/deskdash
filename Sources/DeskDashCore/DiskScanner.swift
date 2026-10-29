import Foundation

/// One file found while scanning.
public struct ScanItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let category: StorageCategory
    public let modified: Date?

    public init(url: URL, bytes: Int64, category: StorageCategory, modified: Date?) {
        self.url = url
        self.bytes = bytes
        self.category = category
        self.modified = modified
    }

    public var name: String { url.lastPathComponent }
}

public struct FolderUsage: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
}

/// What a scan found: space per category, the biggest files in each, and per top-level folder.
public struct ScanResult: Sendable {
    public var roots: [URL]
    public var bytesByCategory: [StorageCategory: Int64] = [:]
    /// The biggest files of each category, biggest first.
    public var largestByCategory: [StorageCategory: [ScanItem]] = [:]
    /// Space per folder directly inside each scanned folder (path -> bytes).
    public var bytesByFolder: [String: Int64] = [:]
    /// Big files not changed in over a year, biggest first.
    public var oldFiles: [ScanItem] = []
    public var oldBytes: Int64 = 0
    public var fileCount = 0
    /// Folders that couldn't be read (usually missing Full Disk Access).
    public var unreadableFolders = 0
    public var finishedAt = Date()
    public var wasCancelled = false

    public init(roots: [URL]) {
        self.roots = roots
    }

    public var totalBytes: Int64 { bytesByCategory.values.reduce(0, +) }

    public func largestFolders(limit: Int = 12) -> [FolderUsage] {
        bytesByFolder.sorted { $0.value > $1.value }.prefix(limit).map { FolderUsage(path: $0.key, bytes: $0.value) }
    }

    /// Takes a file out of the totals after it was moved to the Trash.
    public mutating func remove(_ item: ScanItem) {
        bytesByCategory[item.category, default: 0] -= item.bytes
        largestByCategory[item.category]?.removeAll { $0.id == item.id }
        if oldFiles.contains(where: { $0.id == item.id }) {
            oldFiles.removeAll { $0.id == item.id }
            oldBytes -= item.bytes
        }
        if let folder = bytesByFolder.keys.first(where: { item.url.path.hasPrefix($0 + "/") || item.url.path == $0 }) {
            bytesByFolder[folder, default: 0] -= item.bytes
        }
    }
}

public enum DiskScanner {
    /// Files not changed for this long count as "old".
    public static let oldAge: TimeInterval = 365 * 24 * 3600
    static let smallestListed = Bytes.megabyte
    static let smallestOld = 50 * Bytes.megabyte

    /// Walks every file under `roots` and adds them up. Runs on the calling thread, so call it off the main thread.
    /// `progress` gets the bytes counted so far, now and then.
    public static func scan(roots: [URL], keep: Int = 50, now: Date = Date(),
                            progress: ((Int64) -> Void)? = nil,
                            isCancelled: () -> Bool = { Task.isCancelled }) -> ScanResult {
        var result = ScanResult(roots: roots)
        var largest: [StorageCategory: TopList] = [:]
        var old = TopList(limit: keep)
        var counted: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isVolumeKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)

        for root in roots {
            let rootPath = root.standardizedFileURL.path
            // Files come back with links resolved (/var -> /private/var), so match folders against that path.
            let walkedPath = realpath(rootPath, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? rootPath
            var unreadable = 0
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in unreadable += 1; return true })
            else { continue }

            for case let url as URL in walker {
                if isCancelled() {
                    result.wasCancelled = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
                if values.isDirectory == true {
                    // Another drive mounted inside this one: it gets its own scan.
                    if values.isVolume == true { walker.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                guard bytes > 0 else { continue }

                let category = Classifier.category(forPath: url.path)
                result.fileCount += 1
                result.bytesByCategory[category, default: 0] += bytes
                if let folder = topFolder(of: url.path, under: rootPath)
                    ?? topFolder(of: url.path, under: walkedPath).map({ rootPath + $0.dropFirst(walkedPath.count) }) {
                    result.bytesByFolder[folder, default: 0] += bytes
                }
                if bytes >= smallestListed {
                    let item = ScanItem(url: url, bytes: bytes, category: category,
                                        modified: values.contentModificationDate)
                    largest[category, default: TopList(limit: keep)].add(item)
                    if bytes >= smallestOld, let modified = item.modified, now.timeIntervalSince(modified) > oldAge {
                        old.add(item)
                        result.oldBytes += bytes
                    }
                }
                counted += bytes
                if result.fileCount % 2000 == 0 { progress?(counted) }
            }
            result.unreadableFolders += unreadable
            if result.wasCancelled { break }
        }

        result.largestByCategory = largest.mapValues { $0.sorted() }
        result.oldFiles = old.sorted()
        result.finishedAt = now
        progress?(counted)
        return result
    }

    /// "/Users/troy/Movies" for "/Users/troy/Movies/Trip/clip.mov" under "/Users/troy".
    static func topFolder(of path: String, under root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard let first = rest.split(separator: "/", maxSplits: 1).first else { return nil }
        return prefix + first
    }
}

/// Keeps only the biggest `limit` items without sorting on every insert.
struct TopList {
    let limit: Int
    private(set) var items: [ScanItem] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func add(_ item: ScanItem) {
        items.append(item)
        if items.count > limit * 4 { trim() }
    }

    mutating func trim() {
        items.sort { $0.bytes > $1.bytes }
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    func sorted() -> [ScanItem] {
        var copy = self
        copy.trim()
        return copy.items
    }
}
