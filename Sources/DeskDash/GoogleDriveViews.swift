import AppKit
import DeskDashCore
import SwiftUI

/// Connecting DeskDash to Google Drive: what to do on Google's website, then signing in.
struct GoogleDriveSetupView: View {
    @Environment(GoogleDriveConnection.self) private var google

    var body: some View {
        Form {
            if google.isConnected {
                Section {
                    Label("DeskDash is connected to your Google account.", systemImage: "checkmark.circle")
                    Text("Your Google storage shows under the drives and updates every 5 minutes.")
                        .foregroundStyle(.secondary)
                    Button("Disconnect Google Drive") { google.disconnect() }
                }
            } else {
                Section("1. On Google's website (once)") {
                    Text("Make a \"Desktop app\" sign-in for DeskDash at console.cloud.google.com and download its "
                         + "file (client_secret_….json). DeskDash finds it in Downloads by itself.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if google.client != nil {
                            Label("Google file found", systemImage: "checkmark.circle")
                        } else {
                            Text("No Google file yet").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Look in Downloads Again") { google.loadClientFromDownloads() }
                        Button("Choose File…") { google.chooseClientFile() }
                    }
                }
                Section("2. Sign in") {
                    Text("Your browser opens Google's sign-in. If Google says the app isn't verified, that's normal "
                         + "for your own app: click Continue.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Connect Google Drive") { google.signIn() }
                            .disabled(google.client == nil || google.isSigningIn)
                        if google.isSigningIn {
                            Button("Cancel") { google.cancelSignIn() }
                        }
                    }
                }
            }
            if let status = google.status {
                Section {
                    Text(status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .padding(.vertical, 8)
    }
}

@MainActor
final class GoogleDriveWindowController {
    static let shared = GoogleDriveWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Google Drive"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: GoogleDriveSetupView()
                .environment(GoogleDriveConnection.shared))
            window.center()
            self.window = window
        }
        if !GoogleDriveConnection.shared.isConnected && GoogleDriveConnection.shared.client == nil {
            GoogleDriveConnection.shared.loadClientFromDownloads()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
