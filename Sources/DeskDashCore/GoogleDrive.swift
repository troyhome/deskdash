import CryptoKit
import Foundation
import Security

/// The "Desktop app" client Troy made in Google Cloud (from its downloaded JSON file).
public struct GoogleClient: Codable, Hashable, Sendable {
    public let id: String
    public let secret: String

    public init(id: String, secret: String) {
        self.id = id
        self.secret = secret
    }

    /// Reads Google's client_secret_….json: {"installed": {"client_id": …, "client_secret": …}}.
    public static func parse(_ data: Data) -> GoogleClient? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let app = (json["installed"] ?? json["web"]) as? [String: Any],
              let id = app["client_id"] as? String, let secret = app["client_secret"] as? String,
              !id.isEmpty else { return nil }
        return GoogleClient(id: id, secret: secret)
    }
}

/// Signing in to Google from a desktop app: the browser opens Google's page, Google sends the browser back to a
/// tiny web server DeskDash runs on this Mac only (127.0.0.1), with a one-time code that DeskDash trades for tokens.
public enum GoogleAuth {
    /// Enough to read how much space the account uses; it can't see any files DeskDash didn't make itself.
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// A random secret for this sign-in, and the scrambled form that goes to Google first (PKCE).
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func signInURL(client: GoogleClient, redirect: String, verifier: String, state: String) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // "offline" + "consent": Google also hands over a refresh token, so DeskDash stays signed in.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return parts.url!
    }

    /// The code (or Google's error) from the line the browser sends back: "GET /?state=…&code=… HTTP/1.1".
    public static func callback(fromRequestLine line: String) -> (code: String?, state: String?, error: String?) {
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let items = URLComponents(string: "http://localhost" + target)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return (value("code"), value("state"), value("error"))
    }

    public struct Tokens: Sendable {
        public let accessToken: String
        public let refreshToken: String?
    }

    /// Trades the one-time code for tokens.
    public static func exchange(code: String, verifier: String, redirect: String,
                                client: GoogleClient) async throws -> Tokens {
        try await post(["code": code, "code_verifier": verifier, "redirect_uri": redirect,
                        "grant_type": "authorization_code", "client_id": client.id, "client_secret": client.secret])
    }

    /// A fresh access token (they only last an hour) from the saved refresh token.
    public static func refresh(_ refreshToken: String, client: GoogleClient) async throws -> Tokens {
        try await post(["refresh_token": refreshToken, "grant_type": "refresh_token",
                        "client_id": client.id, "client_secret": client.secret])
    }

    static func post(_ fields: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseTokens(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public static func parseTokens(_ data: Data, status: Int) throws -> Tokens {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let access = json["access_token"] as? String else {
            throw GoogleError.google(json["error_description"] as? String ?? json["error"] as? String
                                     ?? "Google answered with code \(status)")
        }
        return Tokens(accessToken: access, refreshToken: json["refresh_token"] as? String)
    }
}

public enum GoogleError: LocalizedError, Equatable {
    case google(String)

    public var errorDescription: String? {
        switch self {
        case .google(let message): message
        }
    }
}

/// How much of the Google account's storage (Drive, Gmail and Photos together) is used.
public enum GoogleDriveStorage {
    static let aboutURL = URL(string: "https://www.googleapis.com/drive/v3/about?fields=storageQuota")!

    public static func fetch(accessToken: String) async throws -> CloudAccount {
        var request = URLRequest(url: aboutURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let account = parse(data) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw GoogleError.google(message ?? "Google Drive answered with code \(status)")
        }
        return account
    }

    /// {"storageQuota": {"limit": "2199023255552", "usage": "…"}}. Numbers come as text; no limit = unlimited.
    public static func parse(_ data: Data) -> CloudAccount? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let quota = json["storageQuota"] as? [String: Any],
              let usage = (quota["usage"] as? String).flatMap({ Int64($0) }) else { return nil }
        let limit = (quota["limit"] as? String).flatMap { Int64($0) } ?? usage
        return CloudAccount(id: "google", name: "Google Drive",
                            totalBytes: limit, availableBytes: max(0, limit - usage), totalIsGuess: false)
    }
}
