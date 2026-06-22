# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A tiny macOS menu-bar app (SwiftPM, no external dependencies) that tracks two subscriptions — **Codex** and **Claude Code** — showing each one's 5-hour and weekly limit with reset times, and notifying on limit reached / reset. The whole app is ~10 files in `Sources/CodexBarLite/`.

## ⚠️ `CodexBar/` is read-only reference

The `CodexBar/` subfolder is the original full-featured app (~640 files, ~60 providers). It is the *only* reference for how Codex/Claude usage is fetched, but **do not edit anything inside it**. All work goes in the repo root (`Package.swift`, `Sources/CodexBarLite/`).

## Commands

```sh
make build      # debug build (swift build)
make run        # run from terminal — no bundle, so notifications + launch-at-login are disabled
make app        # build CodexBarLite.app (ad-hoc signed, LSUIElement) in the repo root
make install    # build the .app and copy it to /Applications
make clean
```

Requires macOS 14+ and the Swift toolchain. There is no test target.

Menu-bar apps need the bundle: `make run` works for quick iteration but a real test means `make install` then launch from `/Applications`. Each `make app`/`make install` re-signs ad-hoc, which changes the app's identity, so macOS re-prompts for Claude Keychain access after every rebuild — click **Always Allow** again.

## Architecture

Data flows one direction: **clients → monitor → UI**.

- `CodexClient` / `ClaudeClient` — pure `enum`s that read a local OAuth token, do one HTTPS GET, and return a `ProviderUsage`. Each maps its provider-specific JSON onto the shared `UsageWindow { usedPercent, resetsAt }` model in `Model.swift`. This is the layer to touch when an endpoint or credential format changes; nothing above it knows provider details beyond the `ProviderID` enum.
- `UsageMonitor` (`@MainActor @Observable`) — the single source of truth. Polls every 5 min + on popover open. **Each provider refreshes independently** (separate `Task` per provider) so a slow or Keychain-blocked provider never stalls the other. Feeds window transitions to `Notifier` and exposes the per-provider `states` the icon reads.
- `ContentView` (SwiftUI) — the one popover page; observes the monitor. It reports its natural content height via `onHeightChange`; `AppDelegate.resizePopover` clamps that to the screen and sets `popover.contentSize`, so the popover sizes to content but scrolls instead of clipping behind the menu bar.
- `AppDelegate` + `main.swift` — `.accessory` AppKit app, `NSStatusItem` + transient `NSPopover` hosting `ContentView`. The menu-bar glyph (`MenuBarIcon`) draws one colored concentric ring per provider (Apple-Fitness style), each ring's arc = that provider's **5h remaining** fraction; it is non-template (colors always visible) and kept in sync via `withObservationTracking`. The icon is sized to `NSStatusBar.system.thickness` (not a fixed px), with stroke/margin/radii scaled from it, so it fills any bar including taller notched-Mac bars; it's drawn through `NSImage(size:flipped:drawingHandler:)` (re-runs per display → crisp on Retina/non-Retina) and regenerated on `didChangeScreenParametersNotification`. Round-cap overshoot is compensated so each arc spans exactly its fraction (a near-empty ring draws a dot; a depleted provider shows only its gray track).
- `Notifier` — `UNUserNotifications`. On a window entering the depleted state: an immediate "limit reached" plus a notification *scheduled* for `resetsAt` ("limit reset"), so the reset reminder fires even when the app isn't polling at that moment.

### Token handling (the subtle part)

The two providers handle token refresh **differently**, on purpose.

**Codex** auto-refreshes its expired token and **writes the rotated token back to `~/.codex/auth.json`**, keeping the app and the `codex` CLI in sync on one source of truth. When changing this: only mutate the access/refresh/expiry fields, preserve all others, and never write if the existing blob couldn't be read first (so a login is never clobbered).

**Claude is strictly read-only and never refreshes, rotates, or writes a token itself.** Rotating the `claude` CLI's single-use refresh token from here could leave the CLI holding a dead token, and the hard rule is **never break Claude Code**. When our cached/stored token is expired or 401s, `ClaudeClient` asks the CLI to refresh *its own* Keychain token by running `claude auth status` (read-only, non-interactive, consumes no usage; cooldown-gated at 5 min, forced past the cooldown on a 401), then re-reads the store. The CLI stays the sole owner of the credential — so we can never break it. The nudge is best-effort: if it doesn't refresh, the next poll retries and normal `claude` use keeps the Keychain fresh. (`claude` is resolved by probing `~/.local/bin`, `~/.claude/local`, Homebrew, `/usr/local` since GUI apps get a minimal PATH; the spawn has a hard timeout so a child blocked on a prompt can't hang a poll.)

**Claude Keychain prompt avoidance.** The `claude` CLI owns the `Claude Code-credentials` Keychain item, so any other app reading it trips macOS's XARA "wants to access" dialog. The trap specific to this app: it ships **ad-hoc signed** (`make app`/`make install` sign with `-`, no Team ID, a cdhash-only designated requirement), and macOS will **not durably trust an ad-hoc identity in a Keychain ACL** — so an in-process `SecItemCopyMatching` re-prompts even after "Always Allow", every time the token expires (notably whenever the Mac sleeps and the access token lapses, then the popover opens and forces a read). The fix is to **delegate the read to Apple's `security` tool** (`readKeychainViaSecurityCLI` → `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`): the read is then attributed to that stable, Apple-signed binary, which reads the item without a prompt (and, if ever asked, keeps its grant). We never write through it — purely a read. On top of that, `ClaudeClient` layers reads so the claude item is touched rarely: **(1)** an in-memory cache (30 min); **(2)** a *persistent* Keychain item that **we own** (`<bundleid>.claude-oauth-cache`) holding a verbatim copy of the last blob — we created it so reading it back never prompts, and it survives app restarts; **(3)** the credentials file (absent on macOS); **(4)** the claude Keychain via the `security` CLI; **(5)** a direct Security.framework read as a last-resort fallback. Whenever (3)/(4)/(5) yield a token it's written back into our own item via `savePersistentCache`. The direct read (5) is marked no-UI (`LAContext.interactionNotAllowed` + `kSecUseAuthenticationUIFail`) so it fails silently rather than prompting; `interactive` (popover open / manual refresh, threaded `ContentView`/`AppDelegate` → `UsageMonitor.refresh` → `ClaudeClient.fetch`) only governs whether *that* last-resort read may prompt — in practice the `security` CLI handles it first, so background polls and the wake refresh now self-heal prompt-free. The persistent copy is strictly read-only — the CLI stays the sole owner that mints/rotates the real token, so this can never break Claude Code. (After a re-sign the new identity can't read/update the *previous* identity's cache item; that's fine — the `security` CLI still reads claude prompt-free, and the next read reseeds a fresh cache item.) This mirrors upstream's `KeychainCacheStore` + `security`-CLI reader, trimmed to a single item.

`Notifier` and `LaunchAtLogin` no-op gracefully when running unbundled (`UNUserNotificationCenter`/`SMAppService` require a real `.app`), so `make run` doesn't crash.
