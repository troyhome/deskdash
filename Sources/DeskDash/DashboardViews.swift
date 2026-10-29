import AppKit
import DeskDashCore
import SwiftUI

/// The drives and the AI card: shared by the desktop widget and the menu bar.
struct DashboardView: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DeskDash").font(.title3.bold())
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
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
            Divider()
            AITokensPlaceholder()
        }
    }
}

struct DesktopWidgetView: View {
    var body: some View {
        DashboardView()
            .padding(16)
            .frame(width: 320)
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
        .frame(width: 320)
    }
}
