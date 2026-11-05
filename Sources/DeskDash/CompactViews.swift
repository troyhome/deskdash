import DeskDashCore
import SwiftUI

/// Compact mode: each drive and each plan limit becomes a small ring instead of a bar, so the widget takes up less
/// of the screen.

/// A ring split into colored pieces (used space per category, or one piece), with free space left gray.
struct UsageRing: View {
    let segments: [UsageSegment]
    let total: Int64
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            ForEach(pieces, id: \.segment.id) { piece in
                Circle()
                    .trim(from: piece.start, to: piece.end)
                    .stroke(piece.segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .padding(lineWidth / 2)
    }

    private var pieces: [(segment: UsageSegment, start: CGFloat, end: CGFloat)] {
        guard total > 0 else { return [] }
        var start: CGFloat = 0
        return segments.map { segment in
            let end = min(1, start + CGFloat(Double(segment.bytes) / Double(total)))
            defer { start = end }
            return (segment, start, end)
        }
    }
}

/// A drive, iCloud or Google Drive as a ring with its name and free space under it.
struct StorageTile: View {
    let name: String
    let segments: [UsageSegment]
    let total: Int64
    let free: Int64

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                UsageRing(segments: segments, total: total)
                Text("\(usedPercent)%").font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(usedPercent >= 90 ? Color.red : Color.primary)
            }
            .frame(width: 50, height: 50)
            Text(name).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            Text("\(Bytes.format(free)) free").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var usedPercent: Int {
        total > 0 ? Int((Double(total - free) / Double(total) * 100).rounded()) : 0
    }
}

/// The drives and online storage as a grid of rings.
struct CompactDrives: View {
    @Environment(DriveStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 6, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
            ForEach(store.drives) { drive in
                Button {
                    DetailsWindowController.shared.show(driveID: drive.id)
                } label: {
                    StorageTile(name: drive.name, segments: usageSegments(for: drive, scan: store.scans[drive.id]),
                                total: drive.totalBytes, free: drive.availableBytes)
                }
                .buttonStyle(.plain)
                .help("\(drive.name): \(Bytes.format(drive.usedBytes)) of \(Bytes.format(drive.totalBytes)) used")
            }
            ForEach(store.cloud) { account in
                StorageTile(name: account.name,
                            segments: [UsageSegment(id: "used", label: "Used", color: .cyan, bytes: account.usedBytes)],
                            total: account.totalBytes, free: account.availableBytes)
                    .help("\(account.name): \(Bytes.format(account.usedBytes)) of \(Bytes.format(account.totalBytes)) used")
            }
        }
    }
}

/// Each AI provider on one line: name and tokens today, then a small ring per plan limit with "% left" inside.
struct CompactTokens: View {
    @Environment(TokenStore.self) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tokens.usage) { usage in
                let limits = tokens.limits[usage.provider] ?? []
                HStack(spacing: 8) {
                    Circle().fill(usage.provider.color).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(usage.provider.title).font(.callout.weight(.semibold))
                        Text("\(TokenFormat.short(usage.today.total)) today" + (tokens.otherMacs.isEmpty ? "" : ", all Macs"))
                            .help("Tokens today \(tokens.countsScope)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if usage.provider == .anthropic || usage.apiCost30Days > 0 {
                            Text(apiCost(usage))
                                .help("Estimated API charges: tokens at list price plus $10 per 1,000 web searches. "
                                      + "Your real bill is in the Claude Console.")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    Spacer(minLength: 4)
                    ForEach(limits) { limit in
                        LimitRing(limit: limit)
                    }
                }
            }
        }
    }
}

/// "API $0.00", or "API $0.62 today · $4.10 30d".
private func apiCost(_ usage: ProviderUsage) -> String {
    if usage.apiCost30Days == 0 { return "API $0.00" }
    return "API \(APIPrice.text(usage.apiCostToday)) today · \(APIPrice.text(usage.apiCost30Days)) 30d"
}

/// One plan limit as a ring: the colored part is what's used, the number is what's left.
struct LimitRing: View {
    let limit: PlanLimit

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                UsageRing(segments: [UsageSegment(id: "used", label: "Used", color: color,
                                                  bytes: Int64(limit.usedPercent.rounded()))],
                          total: 100, lineWidth: 4)
                Text("\(Int(limit.leftPercent.rounded()))").font(.caption2.monospacedDigit().weight(.semibold))
            }
            .frame(width: 34, height: 34)
            Text(limit.name).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .help("\(limit.name): \(Int(limit.leftPercent.rounded()))% left"
              + (limit.resetsAt.map { ", resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
    }

    private var color: Color {
        limit.usedPercent >= 90 ? .red : limit.usedPercent >= 70 ? .orange : .green
    }
}
