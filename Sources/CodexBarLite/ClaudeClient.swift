import Darwin
import Foundation
import LocalAuthentication
import Security

/// Reads Claude Code usage from the local OAuth credentials that the `claude`
/// CLI stores (Keychain item "Claude Code-credentials", or
/// `~/.claude/.credentials.json`), then GETs `api.anthropic.com/api/oauth/usage`.
///
/// **Strictly read-only on credentials.** Unlike the upstream design, this app
/// never mints, rotates, or writes a token. Rotating the CLI's single-use
/// refresh token from here could leave `claude` holding a dead token, so the
/// hard rule is: never do anything that can break Claude Code. When our token is
/// expired or rejected, we ask the `claude` CLI to refresh *its own* Keychain
/// token (`claude auth status` — read-only, non-interactive, no usage consumed)
/// and then re-read the store. The CLI stays the sole owner of the credential.
enum ClaudeClient {
    enum ClaudeError: LocalizedError {
        case notLoggedIn
        case expired
        case unauthorized
        case rateLimited
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "Not logged in — run `claude` in a terminal."
            case .expired: "Token expired — run `claude` to refresh it."
            case .unauthorized: "Unauthorized — run `claude` to sign in again."
            case .rateLimited: "Anthropic is rate-limiting checks — try again shortly."
            case let .badResponse(code): "Anthropic API error (HTTP \(code))."
            }
        }
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-code/2.1.0"

    /// `interactive == true` permits the macOS Keychain access prompt (used for
    /// user-initiated refreshes); background polls pass `false` so a read that
    /// would prompt fails silently instead. See `readKeychain` / `suppressPrompt`.
    static func fetch(interactive: Bool = false) async throws -> ProviderUsage {
        var creds = try loadCredentials(interactive: interactive)
        if creds.isExpired {
            creds = try await refreshedViaCLI(stale: creds, interactive: interactive, force: false)
        }
        do {
            return try await fetchUsage(creds)
        } catch ClaudeError.unauthorized {
            // Token rejected: nudge the CLI once more (bypassing the cooldown),
            // re-read, and retry. If it still 401s we surface the error.
            creds = try await refreshedViaCLI(stale: creds, interactive: interactive, force: true)
            return try await fetchUsage(creds)
        }
    }

    // MARK: - Usage endpoint

    private static func fetchUsage(_ creds: Credentials) async throws -> ProviderUsage {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200:
            return try parse(data, plan: creds.subscriptionType)
        case 401:
            throw ClaudeError.unauthorized
        case 429:
            throw ClaudeError.rateLimited
        default:
            throw ClaudeError.badResponse(code)
        }
    }

    private static func parse(_ data: Data, plan: String?) throws -> ProviderUsage {
        let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        func window(_ w: UsageResponse.Window?) -> UsageWindow? {
            guard let w, let used = w.utilization else { return nil }
            return UsageWindow(usedPercent: used, resetsAt: parseISODate(w.resetsAt))
        }
        return ProviderUsage(
            fiveHour: window(decoded.fiveHour),
            weekly: window(decoded.sevenDay),
            planName: plan?.capitalized)
    }

    private static func parseISODate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?

            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
    }

    // MARK: - Delegated refresh (the `claude` CLI owns its token)

    /// Don't spawn `claude` on every poll: a token is good for hours, so one
    /// nudge per this interval is plenty. Bypassed on a hard 401 (`force`).
    private static let cliCooldown: TimeInterval = 5 * 60
    private static let cliLock = NSLock()
    nonisolated(unsafe) private static var lastCLINudgeAt: Date?

    /// Returns the freshest store credentials, having asked the CLI to refresh if
    /// needed. **Never refreshes in-app.** Falls back to `stale` when the CLI is
    /// unavailable or hasn't refreshed yet — the caller then surfaces a soft error
    /// and the next poll retries (and `claude`, used normally, refreshes anyway).
    private static func refreshedViaCLI(stale: Credentials, interactive: Bool, force: Bool) async throws -> Credentials {
        // Self-heal: the CLI may have already refreshed the store out-of-band.
        if let latest = try? reloadFromStore(interactive: interactive), !latest.isExpired {
            return latest
        }
        await nudgeCLIToRefresh(force: force)
        return (try? reloadFromStore(interactive: interactive)) ?? stale
    }

    /// Runs `claude auth status` so the CLI validates and (if expired) refreshes
    /// its own Keychain token. Read-only, non-interactive, consumes no usage.
    /// Cooldown-gated; a no-op (returns false) when `claude` can't be found.
    @discardableResult
    private static func nudgeCLIToRefresh(force: Bool) async -> Bool {
        guard reserveCLINudge(force: force) else { return false }
        guard let claude = claudeBinaryURL() else { return false }
        return await runProcess(claude, ["auth", "status"], timeout: 15)
    }

    /// Claims a nudge slot under the cooldown. Synchronous so the lock is never
    /// held across an `await`. Returns false when a nudge ran too recently.
    private static func reserveCLINudge(force: Bool) -> Bool {
        cliLock.lock(); defer { cliLock.unlock() }
        if !force, let last = lastCLINudgeAt, Date().timeIntervalSince(last) < cliCooldown {
            return false
        }
        lastCLINudgeAt = Date()
        return true
    }

    /// Resolves the `claude` binary. GUI apps inherit a minimal PATH, so probe the
    /// standard install locations rather than relying on PATH.
    private static func claudeBinaryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Runs a short-lived helper, discarding its I/O, with a hard timeout so a
    /// stuck child (e.g. one blocked on a Keychain prompt) can never hang a poll.
    private static func runProcess(_ url: URL, _ arguments: [String], timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            // Exactly one resume: terminationHandler fires once when the process
            // exits (including after a timeout `terminate()`); if launch throws,
            // the handler never fires and we resume in the catch instead.
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }

    // MARK: - Credentials

    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt
        }
    }

    /// Returns cached credentials while they're fresh, otherwise reads the store
    /// and caches the result. The cache means routine polls don't touch the
    /// Keychain at all (each read is a chance to trip a macOS access prompt).
    private static func loadCredentials(interactive: Bool) throws -> Credentials {
        if let cached = cachedCredentials() { return cached }
        return try reloadFromStore(interactive: interactive)
    }

    /// Reads the store directly (bypassing the cache) and refreshes the cache.
    /// Used after a CLI nudge so we pick up the newly refreshed token.
    @discardableResult
    private static func reloadFromStore(interactive: Bool) throws -> Credentials {
        let creds = try loadCredentialsFromStore(interactive: interactive)
        storeInCache(creds)
        return creds
    }

    /// Tries the credentials file first (no prompt), then the Keychain.
    private static func loadCredentialsFromStore(interactive: Bool) throws -> Credentials {
        let fileURL = credentialsFileURL()
        if let data = try? Data(contentsOf: fileURL), let creds = try? parseCredentials(data) {
            return creds
        }
        if let data = readKeychain(interactive: interactive), let creds = try? parseCredentials(data) {
            return creds
        }
        throw ClaudeError.notLoggedIn
    }

    // MARK: - In-memory credentials cache

    /// How long a cached read is trusted before we go back to the store (long
    /// enough to skip most polls, short enough to pick up a token the `claude`
    /// CLI rotated out-of-band).
    private static let cacheValidity: TimeInterval = 30 * 60
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedCreds: Credentials?
    nonisolated(unsafe) private static var cachedAt: Date?

    private static func cachedCredentials() -> Credentials? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let cachedCreds, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheValidity else {
            return nil
        }
        return cachedCreds
    }

    private static func storeInCache(_ creds: Credentials) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedCreds = creds
        cachedAt = Date()
    }

    // MARK: - Keychain prompt avoidance

    /// Resolved value of the (deprecated) `kSecUseAuthenticationUIFail` constant,
    /// looked up at runtime so we don't reference deprecated API at compile time.
    private static let uiFailPolicy: String = {
        let path = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(path, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return "u_AuthUIF" }
        return (symbol.assumingMemoryBound(to: CFString?.self).pointee as String?) ?? "u_AuthUIF"
    }()

    /// Make a Keychain query fail silently (`errSecInteractionNotAllowed`) instead
    /// of showing the macOS "wants to access" prompt. Once the app is in the
    /// item's ACL (one "Always Allow"), the read just succeeds with no UI — so
    /// background polls never prompt and never block.
    private static func suppressPrompt(_ query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    private static func credentialsFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    /// Reads the Claude Keychain item. When `interactive` is false the query is
    /// marked no-UI so a read that would prompt fails silently (returns nil)
    /// rather than showing the access dialog on every poll.
    private static func readKeychain(interactive: Bool) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if !interactive { suppressPrompt(&query) }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func parseCredentials(_ data: Data) throws -> Credentials {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let oauth = root.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw ClaudeError.notLoggedIn }
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return Credentials(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth.subscriptionType)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }
}
