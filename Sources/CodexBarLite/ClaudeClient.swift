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
/// token by driving an interactive `/status` session through a PTY (the only
/// thing that makes the CLI perform an authenticated request, and so refresh;
/// `claude auth status` is just a local read that never refreshes). It consumes
/// no usage. We then re-read the store. The CLI stays the sole owner of the
/// credential.
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

    /// Don't spawn `claude` on every poll: a token is good for hours. A nudge
    /// that actually produced a fresh token backs off for `cliCooldownLong`; one
    /// that didn't (e.g. the CLI was still launching, or hit a prompt) keeps
    /// `cliCooldownShort` so the next poll retries soon instead of being stuck for
    /// minutes. Bypassed on a hard 401 (`force`).
    private static let cliCooldownLong: TimeInterval = 5 * 60
    private static let cliCooldownShort: TimeInterval = 30
    private static let cliLock = NSLock()
    nonisolated(unsafe) private static var lastCLINudgeAt: Date?
    nonisolated(unsafe) private static var currentCLICooldown: TimeInterval = 5 * 60

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
        let latest = try? reloadFromStore(interactive: interactive)
        // Only back off for the long interval once we can see a *fresh* token; if
        // the nudge didn't refresh it, the short cooldown stands so the next poll
        // retries soon rather than waiting minutes with a still-expired token.
        if let latest, !latest.isExpired {
            markCLINudgeRefreshed()
        }
        return latest ?? stale
    }

    /// Drives an interactive `claude` `/status` session (see
    /// `runInteractiveStatusViaPTY`) so the CLI performs an authenticated request
    /// and refreshes *its own* Keychain token. Consumes no usage. Cooldown-gated;
    /// a no-op (returns false) when a nudge ran too recently or `claude` can't be
    /// found.
    @discardableResult
    private static func nudgeCLIToRefresh(force: Bool) async -> Bool {
        guard reserveCLINudge(force: force) else { return false }
        guard let claude = claudeBinaryURL() else { return false }
        return await runInteractiveStatusViaPTY(claude, timeout: 15)
    }

    /// Claims a nudge slot under the cooldown, reserving it with the *short*
    /// cooldown; `markCLINudgeRefreshed` extends it to the long cooldown only if
    /// the token actually came back fresh. Synchronous so the lock is never held
    /// across an `await`. Returns false when a nudge ran too recently.
    private static func reserveCLINudge(force: Bool) -> Bool {
        cliLock.lock(); defer { cliLock.unlock() }
        if !force, let last = lastCLINudgeAt, Date().timeIntervalSince(last) < currentCLICooldown {
            return false
        }
        lastCLINudgeAt = Date()
        currentCLICooldown = cliCooldownShort
        return true
    }

    /// Extend the cooldown to the long interval after a confirmed refresh.
    private static func markCLINudgeRefreshed() {
        cliLock.lock(); defer { cliLock.unlock() }
        lastCLINudgeAt = Date()
        currentCLICooldown = cliCooldownLong
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

    /// Drives an interactive `claude` session through a pseudo-terminal, runs the
    /// `/status` slash command, then tears the session down.
    ///
    /// This is the *only* thing that makes the CLI perform an authenticated
    /// request — and therefore refresh its own expired OAuth token, writing the
    /// rotated token back to its Keychain item. `claude auth status` is a local
    /// read that never refreshes (it returns far faster than a network round-trip
    /// takes); `/status` exists only inside an interactive session, so a real TTY
    /// is required. `/status` is a status command, not a model prompt, so **no
    /// usage is consumed.** Mirrors upstream's `ClaudeStatusProbe.touchOAuthAuthPath`.
    ///
    /// Output is discarded; the caller confirms success by re-reading the store.
    /// A hard timeout plus a SIGKILL of the whole process group guarantee a stuck
    /// child (e.g. one waiting on a prompt) can never hang a poll. Returns whether
    /// the session launched.
    private static func runInteractiveStatusViaPTY(_ binary: URL, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: ptyStatusRefresh(binary, timeout: timeout))
            }
        }
    }

    private static func ptyStatusRefresh(_ binary: URL, timeout: TimeInterval) -> Bool {
        // Baseline of the claude-owned blob so we can stop the moment the CLI
        // rotates a fresh token into it (only a successful, *different* read counts).
        let baseline = readKeychainViaSecurityCLI()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var win = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &win) == 0 else { return false }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)
        let primary = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--allowed-tools", ""]
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        let workdir = probeWorkingDirectory()
        process.currentDirectoryURL = workdir
        process.environment = refreshEnvironment(workingDirectory: workdir)

        do {
            try process.run()
        } catch {
            try? primary.close(); try? secondary.close()
            return false
        }
        let pid = process.processIdentifier
        setpgid(pid, pid)  // own process group so the SIGKILL below reaps children too

        var scratch = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        let started = Date()
        var lastStatusSend = Date.distantPast
        var lastKeychainPoll = Date.distantPast
        while process.isRunning, Date() < deadline {
            // Drain the child's output so its PTY buffer can't fill and block it.
            scratch.withUnsafeMutableBytes { _ = read(primaryFD, $0.baseAddress, $0.count) }

            // The trailing Enter accepts the one-time "trust this folder" prompt
            // for our own dir; re-sending `/status` makes it run once the session
            // is ready, regardless of which arrives first.
            let now = Date()
            if now.timeIntervalSince(started) > 0.8, now.timeIntervalSince(lastStatusSend) > 1.0 {
                lastStatusSend = now
                writePTY(primaryFD, "/status\r")
            }
            if now.timeIntervalSince(lastKeychainPoll) > 1.2 {
                lastKeychainPoll = now
                if let baseline, let current = readKeychainViaSecurityCLI(), current != baseline {
                    break  // token rotated into the Keychain — done early
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        if process.isRunning {
            let group = getpgid(pid)
            kill(group > 0 ? -group : pid, SIGKILL)
        }
        process.waitUntilExit()
        try? primary.close(); try? secondary.close()
        return true
    }

    /// An isolated, persistent working directory for the refresh session so
    /// launching `claude` picks up no project `CLAUDE.md` and can't touch the
    /// user's workspace. The one-time "trust this folder" prompt for it is
    /// auto-accepted by the Enter we send; the dir then stays trusted.
    private static func probeWorkingDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent(
            (Bundle.main.bundleIdentifier ?? "CodexBarLite") + "/ClaudeRefresh", isDirectory: true)
        do {
            try fm.createDirectory(at: dir.appendingPathComponent(".claude", isDirectory: true),
                                   withIntermediateDirectories: true)
        } catch {
            return fm.temporaryDirectory
        }
        let settings = dir.appendingPathComponent(".claude/settings.local.json")
        if !fm.fileExists(atPath: settings.path) {
            try? Data(#"{"disableDeepLinkRegistration":"disable"}"#.utf8).write(to: settings)
        }
        return dir
    }

    /// Environment for the refresh session: drop any inherited `ANTHROPIC_*` so
    /// the CLI refreshes the OAuth credential we read (not an API-key override),
    /// and enrich `PATH` since GUI apps inherit a minimal one.
    private static func refreshEnvironment(workingDirectory: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("ANTHROPIC_") { env.removeValue(forKey: key) }
        env["PWD"] = workingDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["\(home)/.local/bin", "\(home)/.claude/local",
                      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extras + (env["PATH"].map { [$0] } ?? [])).joined(separator: ":")
        return env
    }

    private static func writePTY(_ fd: Int32, _ string: String) {
        Array(string.utf8).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
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
    /// and caches the result. Each read is layered so the claude-owned Keychain
    /// (the only thing that can trip a macOS access prompt) is touched as rarely
    /// as possible: in-memory cache → our own persistent Keychain cache → the
    /// credentials file → finally the claude Keychain.
    private static func loadCredentials(interactive: Bool) throws -> Credentials {
        if let cached = cachedCredentials() { return cached }
        // Our own Keychain item survives app restarts and reads back without a
        // prompt (we created it), so a fresh launch normally never has to read
        // the claude-owned item. An expired blob still short-circuits the slow
        // path; `fetch` notices the expiry and nudges the CLI to refresh.
        if let creds = persistentCachedCredentials() {
            storeInCache(creds)
            return creds
        }
        return try reloadFromStore(interactive: interactive)
    }

    /// Reads the source of truth (credentials file, then claude Keychain),
    /// bypassing both caches, then refreshes them. Used after a CLI nudge so we
    /// pick up the newly refreshed token.
    @discardableResult
    private static func reloadFromStore(interactive: Bool) throws -> Credentials {
        let (creds, raw) = try loadCredentialsFromStore(interactive: interactive)
        storeInCache(creds)
        savePersistentCache(raw)
        return creds
    }

    /// Tries the credentials file first (no prompt), then the claude Keychain via
    /// the `security` CLI (no prompt — see `readKeychainViaSecurityCLI`), then a
    /// direct Security.framework read as a last resort. Returns the raw blob
    /// alongside the parsed creds so callers can persist it verbatim.
    private static func loadCredentialsFromStore(interactive: Bool) throws -> (Credentials, Data) {
        let fileURL = credentialsFileURL()
        if let data = try? Data(contentsOf: fileURL), let creds = try? parseCredentials(data) {
            return (creds, data)
        }
        if let data = readKeychainViaSecurityCLI(), let creds = try? parseCredentials(data) {
            return (creds, data)
        }
        if let data = readKeychain(interactive: interactive), let creds = try? parseCredentials(data) {
            return (creds, data)
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

    // MARK: - Persistent (own) Keychain cache

    /// A Keychain item *we* own, holding a verbatim copy of the last credentials
    /// blob we read from the claude store. Because we created it, reading it back
    /// never prompts, and unlike the in-memory cache it survives app restarts —
    /// so a relaunch normally serves the token from here instead of re-reading
    /// the claude-owned item (which is what was making macOS prompt repeatedly).
    ///
    /// This is a read-only *copy*; the claude CLI stays the sole owner that mints
    /// and rotates the real token, so caching here can never break Claude Code.
    private static let cacheKeychainService =
        (Bundle.main.bundleIdentifier ?? "CodexBarLite") + ".claude-oauth-cache"
    private static let cacheKeychainAccount = "claude"

    private static func persistentCachedCredentials() -> Credentials? {
        guard let data = readPersistentCache() else { return nil }
        return try? parseCredentials(data)
    }

    /// No-UI read of our own item: it succeeds silently for us (the creating app)
    /// and, should it ever not (e.g. after an ad-hoc re-sign changes our
    /// identity), fails silently and we fall through rather than surprise-prompt.
    private static func readPersistentCache() -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheKeychainService,
            kSecAttrAccount as String: cacheKeychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        suppressPrompt(&query)
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Upsert the blob into our item. Best-effort: a failure just means the next
    /// launch falls back to reading the claude store again.
    private static func savePersistentCache(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheKeychainService,
            kSecAttrAccount as String: cacheKeychainAccount,
        ]
        let update = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return }
        var add = base
        add[kSecValueData as String] = data
        // Readable whenever the device is unlocked (so background polls work) and
        // never synced off this Mac.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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

    /// Reads the claude Keychain blob by shelling out to Apple's `security` tool
    /// (`find-generic-password -w`).
    ///
    /// This is the key to *not* prompting. A direct in-process `SecItemCopyMatching`
    /// is attributed to *us* — an ad-hoc-signed app whose code identity macOS
    /// won't durably trust, so the "wants to access" grant never sticks and we get
    /// re-prompted (notably whenever the token expires during sleep). Delegating
    /// the read to `/usr/bin/security` attributes it to that stable, Apple-signed
    /// binary instead, which reads the item without a prompt and, if ever asked,
    /// keeps its grant. We never write through it — purely a read.
    ///
    /// Best-effort: returns nil on any failure (missing binary, timeout, non-zero
    /// exit, locked keychain) so callers fall through to the in-process read. A
    /// hard timeout guarantees a stuck child can't hang a poll. Output stays well
    /// under the pipe buffer, so draining after exit can't deadlock.
    private static func readKeychainViaSecurityCLI() -> Data? {
        let securityPath = "/usr/bin/security"
        guard FileManager.default.isExecutableFile(atPath: securityPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = nil
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }

        var data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        return data.isEmpty ? nil : data
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
