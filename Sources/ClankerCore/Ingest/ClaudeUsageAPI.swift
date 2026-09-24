import Foundation
import Security

/// Asks Anthropic for your current Claude limits, the way Claude Code's `/usage` does, using Claude
/// Code's own login from the Keychain. Opt-in and infrequent (see `shouldCheck`). It never refreshes
/// the login token: when it has expired, the check waits until Claude Code refreshes it.
public struct ClaudeUsageAPI: Sendable {
    public struct Credentials: Sendable {
        public var accessToken: String
        public var expiresAt: Date?

        public init(accessToken: String, expiresAt: Date?) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
        }
    }

    public enum Outcome: Sendable, Equatable {
        case updated(readings: Int)
        /// Claude Code's login isn't in the Keychain, or access was declined.
        case noLogin
        /// The token has expired; Claude Code refreshes it next time it runs.
        case loginExpired
        case failed(status: Int?)
    }

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    let credentials: @Sendable () -> Credentials?
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(credentials: @escaping @Sendable () -> Credentials? = ClaudeUsageAPI.keychainCredentials,
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.credentials = credentials
        self.transport = transport
    }

    public func fetch(now: Date = Date()) async -> (Outcome, [Sample]) {
        guard let creds = credentials() else { return (.noLogin, []) }
        if let expires = creds.expiresAt, expires <= now.addingTimeInterval(60) { return (.loginExpired, []) }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("clanker-tracker", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport(request) else { return (.failed(status: nil), []) }
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (status == 401 ? .loginExpired : .failed(status: status), [])
        }
        let usage = (root["utilization"] as? [String: Any]) ?? root
        let samples = ClaudeParser.samples(usage: usage, at: now)
        return (.updated(readings: samples.count), samples)
    }

    /// Claude Code's login, from the Keychain item it keeps (macOS asks once for access).
    public static let keychainCredentials: @Sendable () -> Credentials? = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = ClaudeParser.date(oauth["expiresAt"])
        return Credentials(accessToken: token, expiresAt: expires)
    }

    /// Whether to check now: at most every 30 minutes, only while Claude Code is in use or when the
    /// newest scoped reading (e.g. Fable) is over 6 hours old, and never during a backoff after errors.
    public static func shouldCheck(now: Date, lastCheck: Date?, lastClaudeActivity: Date?, newestScopedReading: Date?,
                                   backoffUntil: Date?) -> Bool {
        if let backoffUntil, now < backoffUntil { return false }
        if let lastCheck, now.timeIntervalSince(lastCheck) < 30 * 60 { return false }
        let active = lastClaudeActivity.map { now.timeIntervalSince($0) <= 30 * 60 } ?? false
        let stale = newestScopedReading.map { now.timeIntervalSince($0) > 6 * 3600 } ?? true
        return active || stale
    }

    /// How long to wait after an outcome before trying again, beyond the usual 30 minutes.
    public static func backoff(after outcome: Outcome) -> TimeInterval? {
        switch outcome {
        case .updated: nil
        case .loginExpired, .noLogin: 3600
        case .failed(let status): status == 429 ? 2 * 3600 : 3600
        }
    }
}
