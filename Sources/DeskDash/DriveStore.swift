import AppKit
import DeskDashCore
import Observation

/// The app's shared state: the mounted drives and what each scan found.
@MainActor @Observable
final class DriveStore {
    static let shared = DriveStore()

    private(set) var drives: [Drive] = []
    /// Online storage (iCloud), checked every few minutes.
    private(set) var cloud: [CloudAccount] = []
    private(set) var scans: [String: ScanResult] = [:]
    /// Bytes counted so far, for drives being scanned right now.
    private(set) var scanProgress: [String: Int64] = [:]

    @ObservationIgnored private var scanTasks: [String: Task<ScanResult, Never>] = [:]
    @ObservationIgnored private var timer: Timer?

    @ObservationIgnored private var cloudTimer: Timer?

    private init() {
        refresh()
        refreshCloud()
        // Free space changes all the time; drives come and go.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in DriveStore.shared.refresh() }
        }
        cloudTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in DriveStore.shared.refreshCloud() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in DriveStore.shared.refresh() }
            }
        }
    }

    func refresh() {
        drives = DriveList.current()
    }

    func refreshCloud() {
        let plan = UserDefaults.standard.object(forKey: Prefs.iCloudPlan) as? Int64
        Task {
            let account = await Task.detached(priority: .utility) { ICloudStorage.current(chosenPlan: plan) }.value
            cloud = account.map { [$0] } ?? []
        }
    }

    /// The iCloud plan size picked by the user (nil = guess it).
    func setICloudPlan(_ bytes: Int64?) {
        UserDefaults.standard.set(bytes, forKey: Prefs.iCloudPlan)
        refreshCloud()
    }

    func drive(id: String?) -> Drive? {
        drives.first { $0.id == id }
    }

    func isScanning(_ drive: Drive) -> Bool {
        scanTasks[drive.id] != nil
    }

    func scan(_ drive: Drive) {
        let id = drive.id
        guard scanTasks[id] == nil else { return }
        let roots = drive.scanRoots
        scanProgress[id] = 0
        let task = Task.detached(priority: .utility) {
            DiskScanner.scan(roots: roots, progress: { bytes in
                Task { @MainActor in DriveStore.shared.updateProgress(id, bytes) }
            })
        }
        scanTasks[id] = task
        Task {
            let result = await task.value
            scanTasks[id] = nil
            scanProgress[id] = nil
            if !result.wasCancelled { scans[id] = result }
        }
    }

    func cancelScan(_ drive: Drive) {
        scanTasks[drive.id]?.cancel()
    }

    private func updateProgress(_ id: String, _ bytes: Int64) {
        if scanTasks[id] != nil { scanProgress[id] = bytes }
    }

    func suggestions(for drive: Drive) -> [Suggestion] {
        Suggestions.make(for: drive, scan: scans[drive.id], otherDrives: drives.filter { $0.id != drive.id })
    }

    /// Moves a file to the Trash (never deletes it outright) and takes it out of the scan.
    func moveToTrash(_ item: ScanItem, on drive: Drive) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        scans[drive.id]?.remove(item)
        refresh()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
