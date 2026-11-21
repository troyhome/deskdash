import Foundation

/// One file found while scanning.
public struct ScanItem: Identifiable, Hashable, Codable, Sendable {
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
public struct ScanResult: Codable, Sendable {
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
    /// False while the scan is still going (the numbers so far), or when it was stopped part way.
    public var isComplete = true

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

    /// Walks every file under `roots` and adds them up. Blocks the calling thread, so call it off the main thread.
    /// Several folders are looked through at once (`workers`): a network disk answers many requests at a time much
    /// faster than one after another. `progress` gets the bytes counted so far about every second; `partial` gets
    /// the results so far every few seconds, so a long scan shows something long before it's done.
    public static func scan(roots: [URL], keep: Int = 50, now: Date = Date(), workers: Int = 6,
                            progress: (@Sendable (Int64) -> Void)? = nil,
                            partial: (@Sendable (ScanResult) -> Void)? = nil,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) -> ScanResult {
        let tally = Tally(roots: roots, keep: keep, now: now, progress: progress, partial: partial)

        // The first two levels of each root are listed here; every folder found at the second level is one piece of
        // work for the workers.
        var work: [(folder: URL, root: ScanRoot)] = []
        for url in roots {
            let root = ScanRoot(url)
            for child in tally.list(url) where !isCancelled() {
                guard let childValues = tally.directoryValues(child) else { continue }
                if childValues.isDirectory == true {
                    if childValues.isVolume == true { continue }
                    for grandchild in tally.list(child) {
                        guard let values = tally.directoryValues(grandchild) else { continue }
                        if values.isDirectory == true {
                            if values.isVolume != true { work.append((grandchild, root)) }
                        } else {
                            tally.count(grandchild, root: root)
                        }
                    }
                } else {
                    tally.count(child, root: root)
                }
            }
        }

        let queue = WorkQueue(work)
        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, work.count))) { _ in
            while !isCancelled(), let item = queue.next() {
                tally.walk(item.folder, root: item.root, isCancelled: isCancelled)
            }
        }
        return tally.finish(cancelled: isCancelled())
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

/// A folder being scanned: its path as given, and with links resolved (files come back with /var as /private/var,
/// so folders are matched against both).
struct ScanRoot: Sendable {
    let path: String
    let walkedPath: String

    init(_ url: URL) {
        path = url.standardizedFileURL.path
        walkedPath = realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
    }

    func topFolder(of file: String) -> String? {
        DiskScanner.topFolder(of: file, under: path)
            ?? DiskScanner.topFolder(of: file, under: walkedPath).map { path + $0.dropFirst(walkedPath.count) }
    }
}

/// Hands out pieces of work to the workers, one at a time.
final class WorkQueue<Item>: @unchecked Sendable {
    private var items: [Item]
    private var index = 0
    private let lock = NSLock()

    init(_ items: [Item]) {
        self.items = items
    }

    func next() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard index < items.count else { return nil }
        index += 1
        return items[index - 1]
    }
}

/// The running totals all workers add to, and the reports sent while the scan goes on.
final class Tally: @unchecked Sendable {
    static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isVolumeKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey, .contentModificationDateKey]
    static let keySet = Set(keys)

    private let lock = NSLock()
    private var result: ScanResult
    private var largest: [StorageCategory: TopList] = [:]
    private var old: TopList
    private var counted: Int64 = 0
    private let keep: Int
    private let now: Date
    private let progress: (@Sendable (Int64) -> Void)?
    private let partial: (@Sendable (ScanResult) -> Void)?
    private var lastProgress = Date()
    private var lastPartial = Date()

    init(roots: [URL], keep: Int, now: Date, progress: (@Sendable (Int64) -> Void)?,
         partial: (@Sendable (ScanResult) -> Void)?) {
        result = ScanResult(roots: roots)
        old = TopList(limit: keep)
        self.keep = keep
        self.now = now
        self.progress = progress
        self.partial = partial
    }

    func list(_ folder: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Self.keys)
        } catch {
            addUnreadable()
            return []
        }
    }

    func directoryValues(_ url: URL) -> URLResourceValues? {
        try? url.resourceValues(forKeys: Self.keySet)
    }

    /// Walks everything inside `folder`.
    func walk(_ folder: URL, root: ScanRoot, isCancelled: () -> Bool) {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Self.keys, options: [],
                                                          errorHandler: { [self] _, _ in addUnreadable(); return true })
        else { return }
        for case let url as URL in walker {
            if isCancelled() { return }
            guard let values = try? url.resourceValues(forKeys: Self.keySet) else { continue }
            if values.isDirectory == true {
                // Another drive mounted inside this one: it gets its own scan.
                if values.isVolume == true { walker.skipDescendants() }
                continue
            }
            count(url, values: values, root: root)
        }
    }

    func count(_ url: URL, root: ScanRoot) {
        guard let values = try? url.resourceValues(forKeys: Self.keySet) else { return }
        count(url, values: values, root: root)
    }

    private func count(_ url: URL, values: URLResourceValues, root: ScanRoot) {
        guard values.isRegularFile == true else { return }
        let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        guard bytes > 0 else { return }
        let category = Classifier.category(forPath: url.path)
        let folder = root.topFolder(of: url.path)

        lock.lock()
        result.fileCount += 1
        result.bytesByCategory[category, default: 0] += bytes
        if let folder { result.bytesByFolder[folder, default: 0] += bytes }
        if bytes >= DiskScanner.smallestListed {
            let item = ScanItem(url: url, bytes: bytes, category: category, modified: values.contentModificationDate)
            largest[category, default: TopList(limit: keep)].add(item)
            if bytes >= DiskScanner.smallestOld, let modified = item.modified,
               now.timeIntervalSince(modified) > DiskScanner.oldAge {
                old.add(item)
                result.oldBytes += bytes
            }
        }
        counted += bytes
        let time = Date()
        let sendProgress = time.timeIntervalSince(lastProgress) >= 1
        if sendProgress { lastProgress = time }
        var snapshot: ScanResult?
        if partial != nil, time.timeIntervalSince(lastPartial) >= 3 {
            lastPartial = time
            snapshot = current(complete: false)
        }
        let total = counted
        lock.unlock()

        if sendProgress { progress?(total) }
        if let snapshot { partial?(snapshot) }
    }

    private func addUnreadable() {
        lock.lock()
        result.unreadableFolders += 1
        lock.unlock()
    }

    /// The results so far. Call with the lock held.
    private func current(complete: Bool) -> ScanResult {
        var copy = result
        copy.largestByCategory = largest.mapValues { $0.sorted() }
        copy.oldFiles = old.sorted()
        copy.finishedAt = Date()
        copy.isComplete = complete
        return copy
    }

    func finish(cancelled: Bool) -> ScanResult {
        lock.lock()
        var final = current(complete: !cancelled)
        final.wasCancelled = cancelled
        let total = counted
        lock.unlock()
        progress?(total)
        return final
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
