import AppKit
import DeskDashCore
import Observation

/// The app's shared state: the mounted drives and what each scan found.
@MainActor @Observable
final class DriveStore {
    static let shared = DriveStore()

    private(set) var drives: [Drive] = []
    /// Online storage (iCloud, and Google Drive once connected), checked every few minutes.
    private(set) var cloud: [CloudAccount] = []
    private(set) var scans: [String: ScanResult] = [:]
    /// Bytes counted so far, for drives being scanned right now.
    private(set) var scanProgress: [String: Int64] = [:]

    @ObservationIgnored private var scanTasks: [String: Task<ScanResult, Never>] = [:]
    @ObservationIgnored private var stopFlags: [String: StopFlag] = [:]
    @ObservationIgnored private var timer: Timer?

    @ObservationIgnored private var cloudTimer: Timer?

    private init() {
        scans = ScanArchive.loadAll()
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
            let iCloud = await Task.detached(priority: .utility) { ICloudStorage.current(chosenPlan: plan) }.value
            let google = await GoogleDriveConnection.shared.storage()
            cloud = [iCloud, google].compactMap { $0 }
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
        // A network disk is slow per question but answers many at once.
        let workers = drive.kind == .network ? 10 : 6
        let stop = StopFlag()
        // The last finished scan stays on screen until the new one has found something.
        let previous = scans[id]
        scanProgress[id] = 0
        stopFlags[id] = stop
        let task = Task.detached(priority: .utility) {
            DiskScanner.scan(roots: roots, workers: workers, progress: { bytes in
                Task { @MainActor in DriveStore.shared.updateProgress(id, bytes) }
            }, partial: { soFar in
                Task { @MainActor in DriveStore.shared.updatePartial(id, soFar) }
            }, isCancelled: { stop.isSet })
        }
        scanTasks[id] = task
        Task {
            let result = await task.value
            scanTasks[id] = nil
            scanProgress[id] = nil
            stopFlags[id] = nil
            if result.wasCancelled {
                // Stopped: keep the last finished scan, or what this one found if there was none.
                scans[id] = previous?.isComplete == true ? previous : result
            } else {
                scans[id] = result
                ScanArchive.save(result, for: id)
            }
        }
    }

    func cancelScan(_ drive: Drive) {
        stopFlags[drive.id]?.set()
    }

    private func updateProgress(_ id: String, _ bytes: Int64) {
        if scanTasks[id] != nil { scanProgress[id] = bytes }
    }

    /// Shows the numbers so far while a scan is still going.
    private func updatePartial(_ id: String, _ soFar: ScanResult) {
        if scanTasks[id] != nil { scans[id] = soFar }
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
