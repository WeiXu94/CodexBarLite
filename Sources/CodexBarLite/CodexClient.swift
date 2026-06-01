import Foundation

/// Reads Codex (ChatGPT) usage from the local `codex` CLI credentials and the
/// ChatGPT backend usage endpoint. Mirrors what the `codex` CLI itself does:
/// load `~/.codex/auth.json`, refresh the OAuth token when stale, then GET
/// `/backend-api/wham/usage`.
enum CodexClient {
    enum CodexError: LocalizedError {
        case notLoggedIn
        case unauthorized
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "Not logged in — run `codex` in a terminal."
            case .unauthorized: "Token expired — run `codex` to sign in again."
            case let .badResponse(code): "ChatGPT API error (HTTP \(code))."
            }
        }
    }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static func fetch() async throws -> ProviderUsage {
        var creds = try loadCredentials()

        if creds.needsRefresh, !creds.refreshToken.isEmpty {
            creds = (try? await refresh(creds)) ?? creds
        }

        do {
            return try await fetchUsage(creds)
        } catch CodexError.unauthorized where !creds.refreshToken.isEmpty {
            // Token rejected: refresh once and retry.
            creds = try await refresh(creds)
            return try await fetchUsage(creds)
        }
    }

    // MARK: - Usage endpoint

    private static func fetchUsage(_ creds: Credentials) async throws -> ProviderUsage {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBarLite", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 200...299:
            return try parse(data)
        case 401, 403:
            throw CodexError.unauthorized
        default:
            throw CodexError.badResponse(code)
        }
    }

    private static func parse(_ data: Data) throws -> ProviderUsage {
        let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        func window(_ snap: UsageResponse.Window?) -> UsageWindow? {
            guard let snap else { return nil }
            return UsageWindow(
                usedPercent: Double(snap.usedPercent),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(snap.resetAt)))
        }
        return ProviderUsage(
            fiveHour: window(decoded.rateLimit?.primaryWindow),
            weekly: window(decoded.rateLimit?.secondaryWindow),
            planName: decoded.planType?.capitalized)
    }

    private struct UsageResponse: Decodable {
        let planType: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }

        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?

            enum CodingKeys: String, CodingKey {
                case primaryWindow = "primary_window"
                case secondaryWindow = "secondary_window"
            }
        }

        struct Window: Decodable {
            let usedPercent: Int
            let resetAt: Int

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
            }
        }
    }

    // MARK: - Credentials (~/.codex/auth.json)

    struct Credentials {
        var accessToken: String
        var refreshToken: String
        var accountId: String?
        var lastRefresh: Date?

        var needsRefresh: Bool {
            guard let lastRefresh else { return true }
            return Date().timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
        }
    }

    private static func authURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let home = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            root = URL(fileURLWithPath: home)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        }
        return root.appendingPathComponent("auth.json")
    }

    private static func loadCredentials() throws -> Credentials {
        let url = authURL()
        guard let data = try? Data(contentsOf: url) else { throw CodexError.notLoggedIn }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.notLoggedIn
        }

        // API-key style auth.json (rare).
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return Credentials(accessToken: apiKey, refreshToken: "", accountId: nil, lastRefresh: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String) ?? (tokens["accessToken"] as? String),
              !accessToken.isEmpty
        else { throw CodexError.notLoggedIn }

        let refreshToken = (tokens["refresh_token"] as? String) ?? (tokens["refreshToken"] as? String) ?? ""
        let accountId = (tokens["account_id"] as? String) ?? (tokens["accountId"] as? String)
        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: accountId,
            lastRefresh: parseDate(json["last_refresh"]))
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - Token refresh (persisted back to auth.json, like the codex CLI)

    private static func refresh(_ creds: Credentials) async throws -> Credentials {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "scope": "openid profile email",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodexError.unauthorized }

        var updated = creds
        updated.accessToken = (json["access_token"] as? String) ?? creds.accessToken
        updated.refreshToken = (json["refresh_token"] as? String) ?? creds.refreshToken
        updated.lastRefresh = Date()
        persist(updated)
        return updated
    }

    /// Writes refreshed tokens back to auth.json in the same shape the codex CLI uses,
    /// preserving any other fields already present.
    private static func persist(_ creds: Credentials) {
        let url = authURL()
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            json = existing
        }
        var tokens = (json["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = creds.accessToken
        tokens["refresh_token"] = creds.refreshToken
        if let accountId = creds.accountId { tokens["account_id"] = accountId }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? out.write(to: url, options: .atomic)
    }
}
