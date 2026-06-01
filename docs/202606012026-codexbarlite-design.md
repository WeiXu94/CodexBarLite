# CodexBar Lite — design notes

2026-06-01

## Goal

Shrink CodexBar to its essence: track only **Codex** and **Claude Code**, show the
**5h** and **weekly** limits with reset times on **one** menu page, and notify on
limit reached / reset. Drop everything else (~60 providers, web/cookie scraping,
cost tracking, charts, widget, localization, multi-page UI, auto-update).

## Key decision: rewrite, not gut

The original app is 640 Swift files / ~141k LOC with ~60 deeply-coupled providers.
Gutting it in place would touch hundreds of files. Instead this is a **fresh,
dependency-free SwiftPM app in the repo root**; the original `CodexBar/` folder is
left untouched as a reference. Result: ~10 source files, no external packages.

The data paths were lifted (conceptually) from the reference app's Codex/Claude
OAuth fetchers, which are simple HTTPS GETs against local OAuth tokens.

## Data sources (verified against the live Codex endpoint)

- **Codex**: read `~/.codex/auth.json` → `tokens.access_token` / `account_id`.
  Refresh via `auth.openai.com/oauth/token` when stale (>8 days) or on 401, then
  persist back to `auth.json` (same shape the `codex` CLI uses — safe). GET
  `chatgpt.com/backend-api/wham/usage`; map `rate_limit.primary_window` → 5h and
  `secondary_window` → weekly (`used_percent` 0–100, `reset_at` unix seconds).
- **Claude Code**: read OAuth JSON from Keychain `Claude Code-credentials` (or
  `~/.claude/.credentials.json`) → `claudeAiOauth.accessToken`. GET
  `api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`; map
  `five_hour` → 5h, `seven_day` → weekly (`utilization` 0–100, `resets_at` ISO-8601).
  **Auto-refresh** (added per user request): when expired/401, POST
  `platform.claude.com/v1/oauth/token` and write the rotated tokens **back to the
  same store** (Keychain via `SecItemUpdate`, or the file), mutating only
  accessToken/refreshToken/expiresAt and only if the existing blob is readable.
  Guards: self-heal re-read (the `claude` CLI may have refreshed already) and a
  15-min backoff after a failed refresh. NB the reference app deliberately does
  *not* refresh CLI-owned tokens (it delegates to the `claude` CLI and keeps its
  own separate cache) to avoid refresh-token rotation races with the CLI; writing
  back to the single shared store is the simplest way to keep app + CLI in sync.

Both models collapse to `UsageWindow { usedPercent, resetsAt }`.

## Architecture

- `Model.swift` — `ProviderID`, `WindowKind`, `UsageWindow`, `ProviderUsage`, `ProviderState`.
- `CodexClient` / `ClaudeClient` — credential read + fetch + parse (no shared deps).
- `UsageMonitor` — `@MainActor @Observable`; polls every 5 min + on open. **Each
  provider refreshes independently** so a slow/blocked provider (e.g. a pending
  Claude Keychain prompt) never stalls the other. (First implementation awaited
  both before applying either — a blocked Claude hid Codex; fixed.)
- `Notifier` — UNUserNotifications. On a window entering the depleted state: an
  immediate "limit reached" plus a `UNTimeIntervalNotificationTrigger` scheduled
  for `resetsAt` ("limit reset"), so the reset reminder fires even if the app is
  not polling at that instant.
- `MenuBarIcon` — template NSImage ring filled to the worst remaining fraction;
  adapts to light/dark menu bars.
- `AppDelegate` / `main.swift` — `.accessory` AppKit app; `NSStatusItem` +
  transient `NSPopover` hosting the SwiftUI `ContentView`. Icon kept in sync via
  `withObservationTracking`.
- `LaunchAtLogin` — `SMAppService.mainApp`.

## Packaging

`Scripts/package_app.sh` builds a release binary, wraps it in `CodexBarLite.app`
(`LSUIElement` menu-bar agent, bundle id `com.codexbarlite.app`), and ad-hoc signs
it (needed for notifications, login item, and stable Keychain ACL). `make install`
copies it to `/Applications`.

## Trade-offs / future

- Ad-hoc signing → Keychain re-prompts after each rebuild. A stable self-signed
  identity would fix this if it becomes annoying.
- A provider stuck on an unanswered Keychain dialog leaves that provider's refresh
  in-flight until answered; the other provider is unaffected.
- No menu-bar text by choice (icon-only); detail lives in the popover.
