# Fix: repeated Claude Keychain prompts ("after a few days")

## Symptom
App keeps prompting for the `Claude Code-credentials` Keychain item even after
clicking "Always Allow". User intuition: "it didn't save the token in its own
keychain/cache."

## Root cause
- On macOS the claude token lives **only** in the Keychain item
  `Claude Code-credentials` (owned by the `claude` CLI). `~/.claude/.credentials.json`
  does **not** exist here (that's the Linux fallback) — confirmed.
- Our `ClaudeClient` cached the loaded token **only in memory** (30 min). That
  cache dies on every app quit. So every relaunch (and every cache expiry) had
  to re-read the *claude-owned* item, and our ad-hoc-signed app isn't a stable
  member of that item's ACL → macOS re-prompts.

## What upstream does that we lacked
`CodexBar` persists a copy of the credentials into **its own** Keychain item
(`KeychainCacheStore`, service `com.steipete.codexbar.cache`, account
`oauth.claude`). That item is owned by CodexBar → reads back with no prompt and
**survives restarts**. Upstream only touches the claude item on first run / when
its own cache is expired. Read order: env → memory → own keychain cache → file →
claude keychain; after reading file/claude it writes back to its own item.

## Fix (CodexBarLite, `Sources/CodexBarLite/ClaudeClient.swift`)
Ported the idea in minimal form — a single persistent Keychain item we own:
- Service `<bundleid>.claude-oauth-cache`, account `claude`, holding the raw
  credentials JSON blob.
- New read order in `loadCredentials`: in-memory → **persistent own-keychain
  cache** → `reloadFromStore` (file → claude keychain).
- `reloadFromStore` now returns the raw blob and calls `savePersistentCache`
  (upsert: `SecItemUpdate`, else `SecItemAdd` with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- Persistent reads use the existing no-UI `suppressPrompt` so the cache can never
  itself surprise-prompt; if it can't read silently (e.g. after a re-sign) it
  falls through.

Strictly a read-only **copy** — the CLI stays the sole owner that mints/rotates
the real token, so this can't break Claude Code. Trimmed vs upstream: one item,
no ACL/owner/fingerprint bookkeeping.

## Caveat
Ad-hoc re-signing on each `make install` changes our identity, so the first read
after a rebuild may still need one "Always Allow" — which then re-seeds our own
cache item. Steady-state prompting (the reported issue) is gone.

## Not adopted (deliberately)
- Explicit `SecAccess`/`SecTrustedApplicationCreateFromPath` ACL (deprecated,
  dlsym dance) — default "creating app is trusted" already gives prompt-free
  reads of our own item for a stable identity.
- `security` CLI reader, fingerprint sync, owner tracking, in-app refresh.
