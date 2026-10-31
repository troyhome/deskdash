import AppKit
import DeskDashCore
import Network
import Observation

/// DeskDash's Google sign-in: the client file Troy downloaded, the saved sign-in, and the browser round trip.
/// The client and the refresh token are kept in the Keychain, never in a file.
@MainActor @Observable
final class GoogleDriveConnection {
    static let shared = GoogleDriveConnection()

    private(set) var client: GoogleClient?
    private(set) var isConnected = false
    /// What's happening, in words ("Waiting for you to sign in in your browser…"), or the last problem.
    private(set) var status: String?
    private(set) var isSigningIn = false

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var accessToken: (token: String, expires: Date)?

    private static let clientKey = "google-client"
    private static let refreshKey = "google-refresh-token"

    private init() {
        client = Keychain.read(Self.clientKey).flatMap { GoogleClient.parse(Data($0.utf8)) }
        isConnected = Keychain.read(Self.refreshKey) != nil
        if client == nil { loadClientFromDownloads() }
    }

    // MARK: The client file

    /// Picks up the newest client_secret_….json in Downloads, so Troy doesn't have to find it.
    func loadClientFromDownloads() {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads,
                                                                   includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        let newest = files.filter { $0.lastPathComponent.hasPrefix("client_secret_") && $0.pathExtension == "json" }
            .max { modified($0) < modified($1) }
        if let newest { useClientFile(newest) }
    }

    func chooseClientFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose the file you downloaded from Google"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { useClientFile(url) }
    }

    private func useClientFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let parsed = GoogleClient.parse(data),
              let text = String(data: data, encoding: .utf8) else {
            status = "That file isn't the one from Google (it should be named client_secret_….json)."
            return
        }
        Keychain.save(text, for: Self.clientKey)
        client = parsed
        status = nil
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // MARK: Signing in

    func signIn() {
        guard let client, !isSigningIn else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            let verifier = GoogleAuth.makeVerifier()
            let state = UUID().uuidString
            listener.newConnectionHandler = { connection in
                Task { @MainActor in GoogleDriveConnection.shared.receive(connection, verifier: verifier, state: state) }
            }
            listener.stateUpdateHandler = { newState in
                Task { @MainActor in
                    let me = GoogleDriveConnection.shared
                    guard case .ready = newState, let port = me.listener?.port else { return }
                    let url = GoogleAuth.signInURL(client: client, redirect: me.redirect(port), verifier: verifier,
                                                   state: state)
                    NSWorkspace.shared.open(url)
                }
            }
            self.listener = listener
            isSigningIn = true
            status = "Waiting for you to sign in to Google in your browser…"
            listener.start(queue: .main)
        } catch {
            status = "Couldn't start the sign-in: \(error.localizedDescription)"
        }
    }

    func cancelSignIn() {
        stopListening()
        status = nil
    }

    private func redirect(_ port: NWEndpoint.Port) -> String {
        "http://127.0.0.1:\(port.rawValue)"
    }

    private func stopListening() {
        listener?.cancel()
        listener = nil
        isSigningIn = false
    }

    /// The browser coming back from Google with the one-time code.
    private func receive(_ connection: NWConnection, verifier: String, state: String) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let firstLine = data.flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "\r\n").first ?? ""
            Task { @MainActor in
                await GoogleDriveConnection.shared.finish(firstLine, connection: connection, verifier: verifier,
                                                          state: state)
            }
        }
    }

    private func finish(_ requestLine: String, connection: NWConnection, verifier: String, state: String) async {
        let answer = GoogleAuth.callback(fromRequestLine: requestLine)
        // Browsers also ask for /favicon.ico and such: only the line with Google's answer counts.
        guard answer.code != nil || answer.error != nil else {
            reply(connection, "")
            return
        }
        guard let client, let port = listener?.port, answer.state == state, let code = answer.code else {
            reply(connection, "DeskDash wasn't connected. You can close this tab and try again.")
            stopListening()
            status = answer.error == "access_denied" ? "Sign-in was cancelled." : "Google didn't sign you in."
            return
        }
        let redirect = redirect(port)
        stopListening()
        do {
            let tokens = try await GoogleAuth.exchange(code: code, verifier: verifier, redirect: redirect,
                                                       client: client)
            guard let refresh = tokens.refreshToken else { throw GoogleError.google("Google gave no lasting sign-in.") }
            Keychain.save(refresh, for: Self.refreshKey)
            accessToken = (tokens.accessToken, Date().addingTimeInterval(3000))
            isConnected = true
            status = nil
            reply(connection, "DeskDash is connected to Google Drive. You can close this tab.")
            DriveStore.shared.refreshCloud()
        } catch {
            reply(connection, "DeskDash couldn't finish connecting. You can close this tab.")
            status = "Couldn't finish signing in: \(error.localizedDescription)"
        }
    }

    private func reply(_ connection: NWConnection, _ message: String) {
        let body = message.isEmpty ? "" : """
            <html><body style="font: 16px -apple-system; text-align: center; margin-top: 80px">\(message)</body></html>
            """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
            + "\(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    func disconnect() {
        Keychain.save("", for: Self.refreshKey)
        accessToken = nil
        isConnected = false
        DriveStore.shared.refreshCloud()
    }

    // MARK: Storage

    /// The account's storage, or nil when not connected. A problem is shown in the window and on the card.
    func storage() async -> CloudAccount? {
        guard isConnected, let client, let refresh = Keychain.read(Self.refreshKey) else { return nil }
        do {
            if accessToken.map({ $0.expires < Date() }) ?? true {
                let tokens = try await GoogleAuth.refresh(refresh, client: client)
                accessToken = (tokens.accessToken, Date().addingTimeInterval(3000))
            }
            let account = try await GoogleDriveStorage.fetch(accessToken: accessToken?.token ?? "")
            status = nil
            return account
        } catch {
            status = "Google Drive: \(error.localizedDescription)"
            return nil
        }
    }
}
