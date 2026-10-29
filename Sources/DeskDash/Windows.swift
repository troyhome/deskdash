import AppKit
import SwiftUI

/// The widget that sits on the desktop: above the wallpaper and icons, below every other window, on all Spaces.
@MainActor
final class DesktopWidgetController: NSObject, NSWindowDelegate {
    static let shared = DesktopWidgetController()
    private var panel: NSPanel?
    /// Where the widget's top-left corner stays. The widget grows and shrinks with its content (drives come and
    /// go), and macOS would otherwise keep the bottom edge still, pushing the top off screen or sliding it down.
    private var topLeft: NSPoint?
    private var lastSize: NSSize?

    func setVisible(_ visible: Bool) {
        if visible { show() } else { panel?.orderOut(nil) }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingController(rootView: DesktopWidgetView()
            .environment(DriveStore.shared)
            .environment(TokenStore.shared))
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
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            topLeft = NSPointFromString(saved)
        } else if let screen = NSScreen.main {
            let area = screen.visibleFrame
            topLeft = NSPoint(x: area.maxX - 340, y: area.maxY - 16)
        }
        panel.delegate = self
        pinTop(panel)
        lastSize = panel.frame.size
        return panel
    }

    private static let positionKey = "desktopWidgetTopLeft"

    /// Puts the top-left corner back where it belongs, kept below the menu bar.
    private func pinTop(_ panel: NSWindow) {
        guard var point = topLeft else { return }
        if let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            point.y = min(point.y, area.maxY)
            point.x = min(max(point.x, area.minX), area.maxX - panel.frame.width)
        }
        if panel.frame.origin.x != point.x || panel.frame.maxY != point.y {
            panel.setFrameTopLeftPoint(point)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        pinTop(panel)
        lastSize = panel.frame.size
    }

    /// Dragged by the user: remember the new spot. (Moves that come with a size change are macOS resizing it.)
    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.frame.size == lastSize else { return }
        let point = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        topLeft = point
        UserDefaults.standard.set(NSStringFromPoint(point), forKey: Self.positionKey)
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
                .environment(DriveStore.shared)
                .environment(TokenStore.shared))
            window.center()
            window.setFrameAutosaveName("DeskDashDetails")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
