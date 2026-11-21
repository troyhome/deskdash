import AppKit
import SwiftUI

/// The DeskDash icon in the menu bar and the panel it opens.
/// The panel always hangs right under the menu bar: below the icon, or at the top right of the screen when the
/// icon can't be seen (hidden behind the camera notch or by a menu bar manager). It keeps its top edge there while
/// its content grows or shrinks (switching Compact, drives coming and going), and it can't be dragged away.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()
    private var statusItem: NSStatusItem?
    private var panel: MenuPanel?
    private var outsideClicks: Any?
    private var escapeKey: Any?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "internaldrive", accessibilityDescription: "DeskDash")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item
    }

    var isOpen: Bool { panel?.isVisible == true }

    /// When the panel last closed. A click on the icon while it's open closes it first (it loses focus), and that
    /// same click mustn't open it again.
    private var closedAt = Date.distantPast

    @objc func toggle() {
        if isOpen { close() } else if Date().timeIntervalSince(closedAt) > 0.3 { open() }
    }

    func open() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        place(panel)
        statusItem?.button?.highlight(true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        place(panel)
        // A click in another app closes the panel, like a menu.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            _ in
            MainActor.assumeIsolated { MenuBarController.shared.close() }
        }
        escapeKey = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { MenuBarController.shared.close() }
                return nil
            }
            return event
        }
    }

    func close() {
        if isOpen { closedAt = Date() }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let escapeKey { NSEvent.removeMonitor(escapeKey) }
        outsideClicks = nil
        escapeKey = nil
        statusItem?.button?.highlight(false)
        panel?.orderOut(nil)
    }

    private func makePanel() -> MenuPanel {
        let host = NSHostingController(
            rootView: MenuBarView()
                .environment(DriveStore.shared)
                .environment(TokenStore.shared))
        host.sizingOptions = [.preferredContentSize]
        let panel = MenuPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.delegate = self
        return panel
    }

    /// Where the panel's top-left corner goes: just under the menu bar, below the icon when it's on screen.
    private func place(_ panel: NSWindow) {
        let size = panel.frame.size
        let gap: CGFloat = 4
        if let button = statusItem?.button, let buttonWindow = button.window,
            let screen = buttonWindow.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonWindow.frame) }),
            buttonWindow.occlusionState.contains(.visible)
        {
            let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            if Self.iconIsShowing(icon, on: screen) {
                let area = screen.visibleFrame
                let top = min(icon.minY, screen.frame.maxY) - gap
                // Left edge under the icon, kept on the screen.
                let x = min(max(icon.minX, area.minX + gap), area.maxX - size.width - gap)
                panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
                return
            }
        }
        // Icon hidden: top right of the screen with the menu bar, under the menu bar.
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - size.width - 8, y: area.maxY - gap))
    }

    /// The icon is really on the screen: not pushed off its edge, and not sitting behind the camera notch.
    private static func iconIsShowing(_ icon: NSRect, on screen: NSScreen) -> Bool {
        guard icon.width > 0, screen.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) else {
            return false
        }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notch = NSRect(
                x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
            if notch.width > 0, notch.intersects(icon) { return false }
        }
        return true
    }

    /// The content changed height: put the top edge back under the menu bar.
    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        place(panel)
    }

    /// Clicking another DeskDash window (the widget, the details window) closes the panel too.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// A borderless panel that still takes clicks and keys.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
