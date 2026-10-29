import AppKit
import DeskDashCore
import SwiftUI

/// The drives and the AI card: shared by the desktop widget and the menu bar. Each part folds away on its own.
struct DashboardView: View {
    @Environment(DriveStore.self) private var store
    @Environment(TokenStore.self) private var tokens
    @AppStorage(Prefs.showDrives) private var showDrives = true
    @AppStorage(Prefs.showAI) private var showAI = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DeskDash").font(.title3.bold())
                Spacer()
                Button {
                    store.refresh()
                    tokens.refresh()
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            SectionHeader(title: "Drives", systemImage: "internaldrive", isOpen: $showDrives, summary: drivesSummary)
            if showDrives {
                ForEach(store.drives) { drive in
                    Button {
                        DetailsWindowController.shared.show(driveID: drive.id)
                    } label: {
                        DriveCard(drive: drive, scan: store.scans[drive.id])
                    }
                    .buttonStyle(.plain)
                    .help("Show what's using space on \(drive.name)")
                }
                if store.drives.isEmpty {
                    Text("No drives found.").foregroundStyle(.secondary)
                }
                ForEach(store.cloud) { account in
                    CloudCard(account: account)
                }
            }
            Divider()
            SectionHeader(title: "AI tokens", systemImage: "sparkles", isOpen: $showAI, summary: aiSummary) {
                Button { TokenSettingsWindowController.shared.show() } label: { Image(systemName: "key") }
                    .buttonStyle(.borderless)
                    .help("Connect API accounts")
            }
            if showAI {
                AITokensCard()
            }
        }
    }

    /// One line shown while Drives is folded: the Mac's own disk.
    private var drivesSummary: String {
        guard let boot = store.drives.first else { return "" }
        return "\(boot.name): \(Bytes.format(boot.availableBytes)) free"
    }

    /// One line shown while AI is folded: the tightest plan limit.
    private var aiSummary: String {
        let tightest = tokens.limits.flatMap { provider, limits in limits.map { (provider, $0) } }
            .min { $0.1.leftPercent < $1.1.leftPercent }
        if let tightest {
            let (provider, limit) = tightest
            return "\(provider.title) \(limit.name.lowercased()): \(Int(limit.leftPercent.rounded()))% left"
        }
        let today = tokens.usage.reduce(Int64(0)) { $0 + $1.today.total }
        return today > 0 ? "\(TokenFormat.short(today)) today" : ""
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, systemImage: String, isOpen: Binding<Bool>, summary: String) {
        self.init(title: title, systemImage: systemImage, isOpen: isOpen, summary: summary) { EmptyView() }
    }
}

/// A part's title with a chevron that folds it away; shows a one-line summary while folded.
struct SectionHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    @Binding var isOpen: Bool
    let summary: String
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, systemImage: String, isOpen: Binding<Bool>, summary: String,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        _isOpen = isOpen
        self.summary = summary
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { isOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                        .foregroundStyle(.secondary)
                    Label(title, systemImage: systemImage).font(.headline)
                    if !isOpen, !summary.isEmpty {
                        Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide \(title)" : "Show \(title)")
            if isOpen { accessory() }
        }
    }
}

struct DesktopWidgetView: View {
    var body: some View {
        DashboardView()
            .padding(16)
            .frame(width: 360)
            .background(DesktopBlur(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct MenuBarView: View {
    @AppStorage(Prefs.showDesktopWidget) private var showWidget = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardView()
            Divider()
            Toggle("Show on desktop", isOn: $showWidget)
                .onChange(of: showWidget) { _, visible in
                    DesktopWidgetController.shared.setVisible(visible)
                }
            HStack {
                Button("Open DeskDash") { DetailsWindowController.shared.show() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
