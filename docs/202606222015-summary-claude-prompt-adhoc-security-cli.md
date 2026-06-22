# Fix (round 2): Claude Keychain still prompts — ad-hoc identity + `security` CLI

Follow-up to `202606191941-summary-claude-keychain-persistent-cache.md`. The
persistent cache shipped, but the user was still prompted — "always when I wake
up the computer."

## Findings
- **Installed app is the latest build** (Jun 20 01:54 > fix commit Jun 19 19:41).
- **Our cache item exists and updates** (`com.codexbarlite.app.claude-oauth-cache`,
  `mdat` current) — so the persistent cache works while the token is valid.
- **App is ad-hoc signed**: `codesign` shows `Signature=adhoc`, `TeamIdentifier=not
  set`, designated requirement is just `cdhash H"…"`. macOS does **not** durably
  trust an ad-hoc identity in a Keychain ACL, so "Always Allow" on the
  claude-owned item never sticks. Every time the token expires (e.g. during
  sleep) and an interactive read hits the claude item, it re-prompts.
- **Wake logic is fine**: `AppDelegate.systemDidWake → monitor.refresh()` is
  non-interactive (no-UI reads), so it never showed the prompt itself. The prompt
  came from opening the popover after wake (interactive) with an expired token.

## Why upstream doesn't have this problem
Beyond `KeychainCacheStore`, upstream reads the claude item through Apple's
`security` CLI (`loadFromClaudeKeychainViaSecurityCLIIfEnabled` →
`security find-generic-password -s … -w`). The read is attributed to the stable,
Apple-signed `/usr/bin/security` binary, which reads without a prompt — sidestepping
the GUI-app XARA dialog that hits our ad-hoc process. Confirmed manually:
`security find-generic-password -w -s "Claude Code-credentials"` returns the blob,
exit 0, no prompt.

## Fix (`Sources/CodexBarLite/ClaudeClient.swift`)
- New `readKeychainViaSecurityCLI()`: spawns `/usr/bin/security find-generic-password
  -s "Claude Code-credentials" -w`, captures stdout (hard 2s timeout, strip trailing
  newline), returns the blob. Best-effort: nil on any failure.
- `loadCredentialsFromStore` read order is now: file → **`security` CLI** → direct
  Security.framework read (no-UI / last-resort). Whatever yields a token is written
  back to our own cache item.
- Read-only — never writes through `security`; the CLI stays the sole token owner.

## Verification (real bundle, prompt-free)
1. Deleted the cache item; `make install` (re-signs → **fresh identity**, cdhash
   `ef0eaf46…` vs old `d2043fb8…`, not in any ACL).
2. Within ~1s of launch the fresh app **recreated** the cache item (mdat current),
   from its **non-interactive** initial poll, with no credentials file and not being
   in claude's ACL. The only path that can produce that is the `security` CLI read —
   and it happened with no prompt. This is the same code path as the wake refresh.

## Caveat
After a re-sign the new identity can't read/update the *previous* identity's cache
item (ACL mismatch); harmless — `security` CLI still reads claude prompt-free and
the next read reseeds a fresh cache item.
