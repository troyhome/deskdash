import AppKit
import SwiftUI

@main
struct DeskDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("DeskDash", systemImage: "internaldrive") {
            MenuBarView()
                .environment(DriveStore.shared)
                .environment(TokenStore.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Prefs.showDesktopWidget: true])
        if UserDefaults.standard.bool(forKey: Prefs.showDesktopWidget) {
            DesktopWidgetController.shared.show()
        }
    }
}

enum Prefs {
    static let showDesktopWidget = "showDesktopWidget"
    static let showDrives = "showDrives"
    static let showAI = "showAI"
    /// The iCloud plan size in bytes, when picked by hand (DeskDash guesses it otherwise).
    static let iCloudPlan = "iCloudPlanBytes"
}
