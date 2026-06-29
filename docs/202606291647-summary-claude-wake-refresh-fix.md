# Claude token not refreshing on wake — root cause & fix

## Symptom
After the Mac wakes from sleep, the Claude card shows an auth error
("Unauthorized — run `claude` to sign in again.") and only recovers after the
user runs `claude` manually in a terminal. The app's automatic refresh never
fixed it on its own.

## Root cause
`ClaudeClient` delegated token refresh to **`claude auth status`**, on the
assumption that it would validate and refresh an expired OAuth token. It does
not. `claude auth status` is a **purely local read** of the stored credential:

- Measured ~0.19 s wall-clock returning status JSON — far less than an OAuth
  network round-trip would take.
- `claude --debug api auth status` shows **zero** network / refresh / token
  activity.

The token only rotates when the CLI makes a **real authenticated request**.
That happens when an interactive session runs something that hits the API —
which is exactly what the user did manually by launching `claude`.

Confirmed against the upstream reference app (`CodexBar/`), the authoritative
source for Claude fetching: it deliberately avoids `auth status` and instead
drives an interactive `/status` session through a **PTY**
(`ClaudeOAuthDelegatedRefreshCoordinator` → `ClaudeStatusProbe.touchOAuthAuthPath`),
then **verifies the Keychain blob actually changed**, retrying on a short
cooldown if it didn't. The lite app's port had silently substituted
`claude auth status` and lost the real refresh mechanism.

### Wake flow that produced the bug
1. Sleep long enough that the access token expires.
2. Wake → `AppDelegate.systemDidWake` → `monitor.refresh()` → `ClaudeClient.fetch`.
3. Token expired → `refreshedViaCLI` → `nudgeCLIToRefresh` runs `claude auth status`
   → **no refresh**.
4. Re-read store → still expired → usage `GET` → **401** → force-nudge → still
   `auth status` → still no refresh → 401 → surfaces "Unauthorized".
5. Recovers only when the user runs `claude` (interactive → authenticated
   request → refresh).

## Fix
Replace the `claude auth status` nudge with an interactive `/status` session
driven through a pseudo-terminal, mirroring upstream. Implemented in
`Sources/CodexBarLite/ClaudeClient.swift`:

- **`runInteractiveStatusViaPTY` / `ptyStatusRefresh`** — `openpty()` + `Process`
  with the slave handle as stdin/stdout/stderr, `--allowed-tools ""`, run in an
  isolated working dir. Sends `/status` (a status slash command — **no model
  usage consumed**), drains output, and SIGKILLs the whole process group on a
  hard 15 s timeout so a stuck child can never hang a poll.
- **Trust prompt** — a fresh working dir triggers a one-time "trust this folder"
  prompt; a periodic Enter auto-accepts it (default = "Yes, I trust this
  folder"), after which the dir stays trusted. The dir is
  `<App Support>/<bundleid>/ClaudeRefresh` so no project `CLAUDE.md` is picked
  up and the user's workspace is never touched.
- **Verification + adaptive cooldown** — baseline the claude Keychain blob via
  the `security` CLI before the session and poll for a change to **exit early**
  the moment the token rotates. `refreshedViaCLI` re-reads the store afterward
  and only extends the cooldown to the long interval (5 min) once it sees a
  *fresh* (non-expired) token; otherwise the short cooldown (30 s) stands so the
  next poll retries soon instead of being stuck for minutes. Still bypassed on a
  hard 401 (`force`).
- **Environment** — strips inherited `ANTHROPIC_*` so the CLI refreshes the
  OAuth credential (not an API-key override) and enriches `PATH` for the GUI
  app's minimal environment.

The hard rule still holds: **we never mint, rotate, or write the token
ourselves** — the `claude` CLI remains the sole owner; we only ask it to refresh
its own credential and then read the result.

## Verification
- `make build` — compiles clean.
- Standalone Swift harness mirroring `ptyStatusRefresh` run against the live CLI:
  `claude` goes fully interactive, the trust prompt is auto-accepted, the
  `/status` panel renders (proving the authenticated request path executes), and
  the session tears down cleanly with no hang. (With the currently-valid token
  no rotation occurs, so the early-exit doesn't fire — correct.)
- The expired-token rotation itself is the exact mechanism upstream relies on
  and the one the user triggers manually; it was not force-tested on the live
  Keychain to honor "never break Claude Code".

## To pick up the fix
`make install` (re-signs ad-hoc; re-approve the Claude Keychain "Always Allow"
once), then launch from `/Applications`. The next post-sleep poll should refresh
silently without the manual `claude` step.
