import Foundation

/// Asks Anthropic for your current Claude limits, the way Claude Code's `/usage` does, using Claude
/// Code's own login from the Keychain. Opt-in and infrequent (see `shouldCheck`). It uses the login
/// token as is and leaves refreshing it to Claude Code (a refresh would rotate Claude Code's login), so
/// when it has expired, the check waits for Claude Code's next refresh and reads the login again.
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

    public struct Response: Sendable {
        public var outcome: Outcome
        public var samples: [Sample] = []
        /// The server's Retry-After, in seconds.
        public var retryAfter: TimeInterval?
    }

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    let credentials: @Sendable () async -> Credentials?
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(credentials: @escaping @Sendable () async -> Credentials? = ClaudeUsageAPI.claudeCodeCredentials,
                transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.credentials = credentials
        self.transport = transport
    }

    public func fetch(now: Date = Date()) async -> Response {
        guard let creds = await credentials() else { return Response(outcome: .noLogin) }
        if let expires = creds.expiresAt, expires <= now.addingTimeInterval(60) { return Response(outcome: .loginExpired) }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("clanker-tracker", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport(request) else { return Response(outcome: .failed(status: nil)) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode
        guard status == 200, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let retryAfter = Self.retryAfter(http?.value(forHTTPHeaderField: "Retry-After"), now: now)
            return Response(outcome: status == 401 ? .loginExpired : .failed(status: status), retryAfter: retryAfter)
        }
        let usage = (root["utilization"] as? [String: Any]) ?? root
        let samples = ClaudeParser.samples(usage: usage, at: now)
        return Response(outcome: .updated(readings: samples.count), samples: samples)
    }

    /// Retry-After as seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Claude Code's login: the Keychain item it keeps, read with `/usr/bin/security` the way Claude Code
    /// itself writes it (so macOS asks at most once, even as Claude Code rotates the item), or
    /// `~/.claude/.credentials.json` where Claude Code keeps it in a file.
    public static let claudeCodeCredentials: @Sendable () async -> Credentials? = {
        if let data = await run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"]),
           let creds = credentials(from: data) {
            return creds
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        return (try? Data(contentsOf: file)).flatMap(credentials(from:))
    }

    /// The `claudeAiOauth` login in Claude Code's credentials JSON (items holding only MCP logins have none).
    static func credentials(from data: Data) -> Credentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return Credentials(accessToken: token, expiresAt: ClaudeParser.date(oauth["expiresAt"]))
    }

    /// Runs a command and returns its output, or nil if it fails or takes over 30 s (e.g. an unanswered
    /// Keychain prompt).
    static func run(_ path: String, _ arguments: [String]) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
        // Read while it runs, so a large output can't fill the pipe and stall it.
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return process.terminationStatus == 0 && process.terminationReason == .exit ? data : nil
    }

    /// Whether to check now: every 5 minutes while Claude Code is answering but its status line isn't
    /// reporting (the desktop app, IDE extensions and Agent SDK apps don't run it, and a terminal session
    /// doesn't re-run it while it waits on subagents); otherwise at most every 30 minutes, only while
    /// Claude Code is in use or when the newest scoped reading (e.g. Fable) is over 6 hours old. Never
    /// during a backoff after errors.
    ///
    /// `lastResponse` is the newest response in Claude Code's transcripts, subagents included;
    /// `lastStatusLine` is when the status line last reported limits.
    public static func shouldCheck(now: Date, lastCheck: Date?, lastResponse: Date?, lastStatusLine: Date?,
                                   newestScopedReading: Date?, backoffUntil: Date?) -> Bool {
        if let backoffUntil, now < backoffUntil { return false }
        let recent = { (d: Date?) in d.map { now.timeIntervalSince($0) <= 30 * 60 } ?? false }
        // The status line runs within a second of each response it sees; allow for slow scripts.
        let unreported = recent(lastResponse) && lastResponse! > (lastStatusLine ?? .distantPast).addingTimeInterval(120)
        if let lastCheck, now.timeIntervalSince(lastCheck) < (unreported ? 5 : 30) * 60 { return false }
        let stale = newestScopedReading.map { now.timeIntervalSince($0) > 6 * 3600 } ?? true
        return recent(lastResponse) || recent(lastStatusLine) || stale
    }

    /// How long to wait after an outcome before trying again, beyond the usual 30 minutes. A rate limit
    /// waits as long as the server asks (an hour if it doesn't say, a day at most).
    public static func backoff(after response: Response) -> TimeInterval? {
        switch response.outcome {
        case .updated, .loginExpired: nil
        case .noLogin: 3600
        case .failed(let status) where status == 429: min(24 * 3600, response.retryAfter ?? 3600)
        case .failed: max(3600, response.retryAfter ?? 0)
        }
    }
}
