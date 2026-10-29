import AppKit
import DeskDashCore
import SwiftUI

extension StorageCategory {
    var color: Color {
        switch self {
        case .apps: .blue
        case .photos: .orange
        case .videos: .purple
        case .music: .pink
        case .documents: .teal
        case .archives: .brown
        case .developer: .indigo
        case .caches: .yellow
        case .backups: .mint
        case .trash: .red
        case .other: Color(white: 0.62)
        }
    }
}

extension Drive {
    var symbolName: String {
        switch kind {
        case .internalDisk: "internaldrive"
        case .external: "externaldrive"
        case .network: "server.rack"
        }
    }
}

/// One colored piece of a usage bar.
struct UsageSegment: Identifiable {
    let id: String
    let label: String
    let color: Color
    let bytes: Int64
}

/// The colored pieces for a drive: one per category once it's scanned, or a single "Used" piece before that.
func usageSegments(for drive: Drive, scan: ScanResult?) -> [UsageSegment] {
    guard let scan else {
        return [UsageSegment(id: "used", label: "Used", color: .accentColor, bytes: drive.usedBytes)]
    }
    var segments = StorageCategory.allCases
        .compactMap { category -> UsageSegment? in
            let bytes = scan.bytesByCategory[category] ?? 0
            return bytes > 0 ? UsageSegment(id: category.rawValue, label: category.title, color: category.color,
                                            bytes: bytes) : nil
        }
        .sorted { $0.bytes > $1.bytes }
    let rest = drive.usedBytes - scan.totalBytes
    if rest > 0 {
        segments.append(UsageSegment(id: "system", label: drive.isBoot ? "System & other" : "Not scanned",
                                     color: Color(white: 0.42), bytes: rest))
    }
    return segments
}

/// A Disk Utility style bar: colored used space, gray free space.
struct UsageBar: View {
    let segments: [UsageSegment]
    let total: Int64
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * fraction(segment.bytes)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: height / 3))
    }

    private func fraction(_ bytes: Int64) -> CGFloat {
        total > 0 ? CGFloat(Double(bytes) / Double(total)) : 0
    }
}

/// Colored dots with a name and size, under a usage bar.
struct UsageLegend: View {
    let segments: [UsageSegment]
    let freeBytes: Int64

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(segments) { segment in
                entry(segment.label, segment.bytes, segment.color)
            }
            entry("Free", freeBytes, Color.secondary.opacity(0.3))
        }
    }

    private func entry(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).lineLimit(1)
            Text(Bytes.format(bytes)).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

/// A drive's name, free space and bar, for the widget and the menu bar.
struct DriveCard: View {
    let drive: Drive
    let scan: ScanResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: drive.symbolName).foregroundStyle(.secondary)
                Text(drive.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(Bytes.format(drive.availableBytes)) free")
                    .font(.caption)
                    .foregroundStyle(drive.usedFraction >= 0.9 ? Color.red : Color.secondary)
            }
            UsageBar(segments: usageSegments(for: drive, scan: scan), total: drive.totalBytes, height: 9)
            Text("\(Bytes.format(drive.usedBytes)) of \(Bytes.format(drive.totalBytes)) used")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// The frosted see-through background of the desktop widget.
struct DesktopBlur: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}
