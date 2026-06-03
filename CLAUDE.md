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

Both providers auto-refresh expired tokens and **write the rotated token back to the same store they read from** (Codex: `~/.codex/auth.json`; Claude: the `Claude Code-credentials` Keychain item or `~/.claude/.credentials.json`). This keeps the app and the `codex`/`claude` CLIs in sync on one source of truth — the only safe way to rotate single-use refresh tokens. When changing this: only mutate the access/refresh/expiry fields, preserve all others, and never write if the existing blob couldn't be read first (so a login is never clobbered). Claude refresh has a 15-min backoff and a self-heal re-read in case the CLI refreshed first.

`Notifier` and `LaunchAtLogin` no-op gracefully when running unbundled (`UNUserNotificationCenter`/`SMAppService` require a real `.app`), so `make run` doesn't crash.
