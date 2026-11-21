import AppKit
import SwiftUI

/// Plain AppKit start-up: the menu bar icon, its panel and the desktop widget are all made by hand.
/// (SwiftUI's own menu bar panel slid down the screen whenever its content changed height, and couldn't be moved.)
@main
enum DeskDashMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.mainMenu = AppDelegate.makeMainMenu()
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Not shown (DeskDash has no menu bar of its own), but it makes Copy, Paste, Select All and Close work by keys.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DeskDash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Prefs.showDesktopWidget: true])
        MenuBarController.shared.install()
        if UserDefaults.standard.bool(forKey: Prefs.showDesktopWidget) {
            DesktopWidgetController.shared.show()
        }
    }
}

enum Prefs {
    static let showDesktopWidget = "showDesktopWidget"
    static let showDrives = "showDrives"
    static let showAI = "showAI"
    /// Rings instead of bars, for a smaller widget.
    static let compact = "compactMode"
    /// The iCloud plan size in bytes, when picked by hand (DeskDash guesses it otherwise).
    static let iCloudPlan = "iCloudPlanBytes"
}
