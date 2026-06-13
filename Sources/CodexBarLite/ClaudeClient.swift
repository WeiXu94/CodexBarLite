import Darwin
import Foundation
import LocalAuthentication
import Security

/// Reads Claude Code usage from the local OAuth credentials that the `claude`
/// CLI stores (Keychain item "Claude Code-credentials", or
/// `~/.claude/.credentials.json`), then GETs `api.anthropic.com/api/oauth/usage`.
///
/// Auto-refresh: when the token is expired (or rejected), we refresh it via
/// Anthropic's OAuth token endpoint and write the rotated token back to the same
/// store we read it from — keeping the app and the `claude` CLI in sync on a
/// single source of truth (the only safe way to rotate refresh tokens). We never
/// touch any field other than the access token, refresh token, and expiry, and we
/// only write when we could read the existing blob, so we can't clobber a login.
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
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let keychainService = "Claude Code-credentials"
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-code/2.1.0"

    /// After a failed refresh, don't retry until this time (avoids hammering the
    /// token endpoint with a dead refresh token every poll).
    nonisolated(unsafe) private static var refreshBlockedUntil: Date?
    private static let refreshBackoff: TimeInterval = 15 * 60

    /// `interactive == true` permits the macOS Keychain access prompt (used for
    /// user-initiated refreshes); background polls pass `false` so a read that
    /// would prompt fails silently instead. See `readKeychain` / `suppressPrompt`.
    static func fetch(interactive: Bool = false) async throws -> ProviderUsage {
        var creds = try loadCredentials(interactive: interactive)
        if creds.isExpired {
            creds = try await refresh(from: creds)
        }
        do {
            return try await fetchUsage(creds)
        } catch ClaudeError.unauthorized {
            creds = try await refresh(from: creds, force: true)
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

    // MARK: - Token refresh

    /// Refresh the access token and persist the rotated tokens back to their store.
    /// `force` refreshes even if `creds` looks unexpired (used on a 401).
    private static func refresh(from creds: Credentials, force: Bool = false) async throws -> Credentials {
        // Self-heal: the `claude` CLI may have refreshed the store already. Read
        // the store directly (bypassing our cache) and non-interactively so we can
        // pick that up without a prompt.
        let latest = (try? loadCredentialsFromStore(interactive: false)) ?? creds
        if !latest.isExpired, force ? latest.accessToken != creds.accessToken : true {
            storeInCache(latest)
            return latest
        }

        if let until = refreshBlockedUntil, Date() < until { throw ClaudeError.expired }
        guard let refreshToken = latest.refreshToken, !refreshToken.isEmpty else {
            throw ClaudeError.expired
        }

        do {
            let refreshed = try await performRefresh(refreshToken: refreshToken, base: latest)
            persist(refreshed)
            storeInCache(refreshed)
            refreshBlockedUntil = nil
            return refreshed
        } catch {
            refreshBlockedUntil = Date().addingTimeInterval(refreshBackoff)
            throw ClaudeError.expired
        }
    }

    private static func performRefresh(refreshToken: String, base: Credentials) async throws -> Credentials {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = (components.percentEncodedQuery ?? "").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClaudeError.unauthorized
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return Credentials(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken ?? refreshToken,
            expiresAt: Date(timeIntervalSinceNow: TimeInterval(decoded.expiresIn)),
            subscriptionType: base.subscriptionType,
            source: base.source)
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    // MARK: - Persisting rotated tokens

    /// Writes the rotated tokens back into the store we read from, mutating only
    /// the three OAuth fields and preserving everything else. No-op if the
    /// existing blob can't be read (so a login is never clobbered).
    private static func persist(_ creds: Credentials) {
        switch creds.source {
        case let .file(url):
            guard let existing = try? Data(contentsOf: url),
                  let blob = updatedBlob(existing: existing, creds: creds)
            else { return }
            try? blob.write(to: url, options: .atomic)
        case .keychain:
            guard let existing = readKeychain(interactive: false),
                  let blob = updatedBlob(existing: existing, creds: creds)
            else { return }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
            ]
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: blob] as CFDictionary)
        }
    }

    private static func updatedBlob(existing: Data, creds: Credentials) -> Data? {
        guard var root = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
            return nil
        }
        var oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = creds.accessToken
        if let refreshToken = creds.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = creds.expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }
        root["claudeAiOauth"] = oauth
        return try? JSONSerialization.data(withJSONObject: root)
    }

    // MARK: - Credentials

    enum Source {
        case keychain
        case file(URL)
    }

    struct Credentials {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let subscriptionType: String?
        let source: Source

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
        let creds = try loadCredentialsFromStore(interactive: interactive)
        storeInCache(creds)
        return creds
    }

    /// Tries the credentials file first (no prompt), then the Keychain.
    private static func loadCredentialsFromStore(interactive: Bool) throws -> Credentials {
        let fileURL = credentialsFileURL()
        if let data = try? Data(contentsOf: fileURL), let creds = try? parseCredentials(data, source: .file(fileURL)) {
            return creds
        }
        if let data = readKeychain(interactive: interactive), let creds = try? parseCredentials(data, source: .keychain) {
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

    private static func parseCredentials(_ data: Data, source: Source) throws -> Credentials {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let oauth = root.claudeAiOauth,
              let token = oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { throw ClaudeError.notLoggedIn }
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000.0) }
        return Credentials(
            accessToken: token,
            refreshToken: oauth.refreshToken,
            expiresAt: expiresAt,
            subscriptionType: oauth.subscriptionType,
            source: source)
    }

    private struct Root: Decodable {
        let claudeAiOauth: OAuth?
    }

    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let subscriptionType: String?
    }
}
