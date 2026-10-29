import AppKit
import SwiftUI

/// The widget that sits on the desktop: above the wallpaper and icons, below every other window, on all Spaces.
@MainActor
final class DesktopWidgetController {
    static let shared = DesktopWidgetController()
    private var panel: NSPanel?

    func setVisible(_ visible: Bool) {
        if visible { show() } else { panel?.orderOut(nil) }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingController(rootView: DesktopWidgetView().environment(DriveStore.shared))
        host.sizingOptions = [.preferredContentSize]
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !panel.setFrameUsingName("DeskDashWidget"), let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - 340, y: area.maxY - 20))
        }
        panel.setFrameAutosaveName("DeskDashWidget")
        return panel
    }
}

/// Which drive the details window shows.
@MainActor @Observable
final class DetailsSelection {
    var driveID: String?
}

/// The full window with drill-down and suggestions. Opened from the widget or the menu bar.
@MainActor
final class DetailsWindowController {
    static let shared = DetailsWindowController()
    private var window: NSWindow?
    private let selection = DetailsSelection()

    func show(driveID: String? = nil) {
        if let driveID {
            selection.driveID = driveID
        } else if selection.driveID == nil {
            selection.driveID = DriveStore.shared.drives.first?.id
        }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "DeskDash"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DetailsView(selection: selection)
                .environment(DriveStore.shared))
            window.center()
            window.setFrameAutosaveName("DeskDashDetails")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
