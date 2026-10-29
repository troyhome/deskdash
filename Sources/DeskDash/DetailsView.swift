import AppKit
import DeskDashCore
import SwiftUI

struct DetailsView: View {
    @Environment(DriveStore.self) private var store
    @Bindable var selection: DetailsSelection

    var body: some View {
        NavigationSplitView {
            List(store.drives, selection: $selection.driveID) { drive in
                Label(drive.name, systemImage: drive.symbolName).tag(drive.id)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 210)
        } detail: {
            if let drive = store.drive(id: selection.driveID) {
                DriveDetailView(drive: drive).id(drive.id)
            } else {
                ContentUnavailableView("Pick a drive", systemImage: "internaldrive")
            }
        }
    }
}

/// Pages you can drill into from a drive.
enum DetailRoute: Hashable {
    case category(StorageCategory)
    case suggestion(String)
    case oldFiles
}

struct DriveDetailView: View {
    @Environment(DriveStore.self) private var store
    let drive: Drive
    @State private var path = NavigationPath()

    private var scan: ScanResult? { store.scans[drive.id] }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    overview
                    scanStatus
                    if let scan {
                        categories(scan)
                        folders(scan)
                    }
                    suggestions
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(drive.name)
            .navigationDestination(for: DetailRoute.self) { route in
                switch route {
                case .category(let category):
                    ItemListView(drive: drive, title: category.title,
                                 items: store.scans[drive.id]?.largestByCategory[category] ?? [])
                case .suggestion(let id):
                    let suggestion = store.suggestions(for: drive).first { $0.id == id }
                    ItemListView(drive: drive, title: suggestion?.title ?? "Suggestion",
                                 note: suggestion?.detail, items: suggestion?.items ?? [])
                case .oldFiles:
                    ItemListView(drive: drive, title: "Not changed in a year",
                                 items: store.scans[drive.id]?.oldFiles ?? [])
                }
            }
        }
    }

    // MARK: Sections

    private var overview: some View {
        let segments = usageSegments(for: drive, scan: scan)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: drive.symbolName).font(.title2).foregroundStyle(.secondary)
                Text(drive.name).font(.title2.bold())
                Spacer()
                Text("\(Bytes.format(drive.usedBytes)) used of \(Bytes.format(drive.totalBytes))")
                    .foregroundStyle(.secondary)
            }
            UsageBar(segments: segments, total: drive.totalBytes, height: 22)
            UsageLegend(segments: segments, freeBytes: drive.availableBytes)
        }
    }

    @ViewBuilder private var scanStatus: some View {
        if store.isScanning(drive) {
            HStack {
                Text("Looking through files... \(Bytes.format(store.scanProgress[drive.id] ?? 0)) counted so far.")
                Spacer()
                Button("Stop") { store.cancelScan(drive) }
            }
        } else if let scan {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Looked through \(scan.fileCount.formatted()) files \(scan.finishedAt.formatted(.relative(presentation: .named))).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Analyze again") { store.scan(drive) }
                }
                if scan.unreadableFolders > 0 {
                    HStack {
                        Text("\(scan.unreadableFolders) folders were skipped because DeskDash isn't allowed to read them.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Allow Full Disk Access") {
                            let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                            NSWorkspace.shared.open(URL(string: url)!)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        } else {
            HStack {
                Text(drive.isBoot
                     ? "Analyze to see what's using space in your home folder and Applications."
                     : "Analyze to see what's using space on this drive.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Analyze") { store.scan(drive) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func categories(_ scan: ScanResult) -> some View {
        func size(_ category: StorageCategory) -> Int64 { scan.bytesByCategory[category] ?? 0 }
        let rows = StorageCategory.allCases.filter { size($0) > 0 }.sorted { size($0) > size($1) }
        let biggest = rows.first.map(size) ?? 1
        return section("Categories") {
            ForEach(rows) { category in
                let bytes = size(category)
                NavigationLink(value: DetailRoute.category(category)) {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbolName)
                            .foregroundStyle(category.color)
                            .frame(width: 22)
                        Text(category.title).frame(width: 170, alignment: .leading)
                        ProportionBar(fraction: Double(bytes) / Double(biggest), color: category.color)
                        Text(Bytes.format(bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func folders(_ scan: ScanResult) -> some View {
        let rows = scan.largestFolders()
        let biggest = rows.first?.bytes ?? 1
        return section("Biggest folders") {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 22)
                    Text((row.path as NSString).lastPathComponent)
                        .lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                        .help(row.path)
                    ProportionBar(fraction: Double(row.bytes) / Double(biggest), color: .accentColor)
                    Text(Bytes.format(row.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Button { store.reveal(URL(fileURLWithPath: row.path)) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            if scan.oldBytes > 0 {
                NavigationLink(value: DetailRoute.oldFiles) {
                    Text("\(Bytes.format(scan.oldBytes)) in big files not changed in over a year")
                        .font(.callout)
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private var suggestions: some View {
        let tips = store.suggestions(for: drive)
        if !tips.isEmpty {
            section("Suggestions") {
                ForEach(tips) { tip in
                    SuggestionRow(suggestion: tip)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(suggestion.kind.rawValue)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color))
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title).font(.body.weight(.medium))
                Text(suggestion.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if suggestion.bytes > 0 {
                Text(Bytes.format(suggestion.bytes)).monospacedDigit()
            }
            if !suggestion.items.isEmpty {
                NavigationLink(value: DetailRoute.suggestion(suggestion.id)) {
                    Text("See files")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var color: Color {
        switch suggestion.kind {
        case .delete: .red
        case .consolidate: .blue
        case .backUp: .green
        case .review: .orange
        }
    }
}

struct ProportionBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.8))
                .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
        }
        .frame(height: 8)
    }
}

/// A list of files with Show in Finder and Move to Trash.
struct ItemListView: View {
    @Environment(DriveStore.self) private var store
    let drive: Drive
    let title: String
    var note: String? = nil
    let items: [ScanItem]

    @State private var pendingTrash: ScanItem?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let note {
                Text(note).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("No big files here.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1)
                        Text(item.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let modified = item.modified {
                        Text(modified.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(Bytes.format(item.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Button { store.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    Button { pendingTrash = item } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Move to Trash")
                }
            }
        }
        .navigationTitle(title)
        .confirmationDialog("Move \"\(pendingTrash?.name ?? "")\" to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { item in
            Button("Move to Trash", role: .destructive) {
                do {
                    try store.moveToTrash(item, on: drive)
                } catch {
                    errorMessage = "Couldn't move it to the Trash. Some drives (like network shares) have no Trash; "
                        + "you can delete it in Finder instead.\n\n\(error.localizedDescription)"
                }
            }
        } message: { item in
            Text("This frees \(Bytes.format(item.bytes)) once you empty the Trash. You can put it back until then.")
        }
        .alert("Not moved", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
