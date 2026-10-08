# Updates, changelog and announcements (R114)

Status: design approved by the coordinator 2026-10-04; steps 1-3 built. Owner: updates lead.

Lawrence (R114): background download, the indicator only when the update is ready, one click installs at once, install on quit, great defaults with every part customizable, an amazing changelog, and a minimal Linear/Notion-style stacking announcement card above Settings that can be hidden permanently and brought back.

## 1. Auto-update

`UpdateFlow` (CmuxNextUpdater) is a pure gate over Sparkle's phase: hidden -> checking -> available (downloads off) -> downloading -> ready -> waiting (a click held by busy agents) -> installing. The App feeds events and performs effects (`install`, `download`, `confirmInterrupt`, `quit`).

- No UI until the update is ready. Background checks, downloads and failures show nothing; a check the user asked for shows its progress and result.
- Ready: the "Update ready" card (card stack, section 3) and the Settings badge. One click installs and relaunches. An app relaunch stops no terminal (the daemon keeps every PTY; a newer daemon adopts the hosts, `terminal_host_recovery/upgrade.rs`).
- Busy agents (`AgentState.working` in the local daemon store, read through observation) hold the click: the card says "waits for N agents" and the install runs when they finish. Install Now asks through CmuxDialog; until the dialog host lands it keeps waiting (never interrupts agents).
- Install on quit (default on): Sparkle installs a staged update as the app exits. Off: the quit replies Skip to Sparkle's held ready prompt, which cancels the installer without recording a skipped version, so the next check offers the update again.
- Settings (`updates.*`, General > Updates, cmux.json, React Settings): `checkAutomatically` (true), `checkIntervalSeconds` (3600, 900...604800), `downloadAutomatically` (true; off makes a found update an available card whose click downloads and installs), `installOnQuit` (true), `notify` (`card` | `badge` | `silent`), `quietHours` (`{start, end}`, off; hides the card only). Agents may set `notify` and `quietHours` only.
- Later steps: `updates.meteredNetwork` (defer automatic downloads on Low Data Mode), `updates.keepPreviousVersions` (1) with `cmux update rollback` (refused, with a clear message, when the daemon store schema is newer than the old build can read), channel (cmux-next: nightly now, stable later; the classic switch stays in cmux-hq), CLI `cmux update check|install|status|channel|rollback` (needs a cmux-tui window).

### Shared bundle id (user rule)

Classic NIGHTLY and cmux-next NIGHTLY share `com.cmuxterm.app.nightly` by decision (R78, passkeys). They share one defaults domain, one Sparkle cache (`~/Library/Caches/com.cmuxterm.app.nightly`), one Sparkle installer service name and `/tmp/cmux-nightly.sock`. So one of them installed per Mac is a real user rule, and the update path must survive a user who switches: a staged update or Sparkle defaults left by the other app must not install the wrong build. Sparkle's own guards cover the install (each feed's items carry its own key and `sparkle:channel`; cmux-next accepts only channel `cmux-next` and its own EdDSA key). Open: clear a staged update whose feed does not match this app's feed at launch.

### Testing

- `scripts/cmux-next/update-e2e.py` (fleet entry `scripts/measure/update-e2e.sh`, class exclusive) installs a real older nightly-next build, stages the newer one through Sparkle, proves install on quit, version, kept terminals (output, shell PID, still answers), the delta download and, with `--click`, the one-click install with Sparkle's relaunch. Host rules: Aqua session, no `com.cmuxterm.app.nightly` installed or running; it removes only what it created.
- Test feed (built): `updates.test_feed {url, pinned}` on DEV and NIGHTLY builds. Signatures are always required (the app's own EdDSA key), https anywhere and http only on loopback, a Test Update Feed card and `updates.status.test_feed` show it while active, and it resets on relaunch unless pinned. No palette entry to set it yet (it needs a text prompt; CmuxDialog); the card's Use Real Feed clears it.
- Planned e2e steps: an agent session and an in-progress turn survive the update (agent hosts landed in b41a3b8756f, `_acpmux/status.agentHosts`); the R114 card shows in the flow once a nightly carries it.

### Rollback (next step; refusal is the safety rule)

Decision (coordinator, 2026-10-04): refuse a rollback, with a clear message, when the daemon store schema is newer than the old build can read.

- Keep previous versions: right before Sparkle installs, the running bundle is cloned (APFS `clonefile`, no extra disk until blocks change) to `~/Library/Application Support/cmux-next/<bundle id>/versions/<build>/`. `updates.keepPreviousVersions` (default 1, 0...5) prunes the oldest.
- Each build stamps `CmuxStoreSchemas` into Info.plist: every daemon store and protocol it can read (`workspace_registry`, `conversation_store`, the terminal-host protocol, ...), printed by the bundled `cmux-tui store schemas --json` at build time.
- `cmux update rollback [--to BUILD]` (palette "Roll Back to Previous Version", app op `updates.rollback`): a pure `RollbackDecision` compares the kept build's `CmuxStoreSchemas` with what the running daemon reports as stored (`store.schemas`, the owner reads its own meta tables). Refused when any stored version is newer than the kept build reads, when the kept build has no `CmuxStoreSchemas` (it predates rollback), or when its code signature or team differs. The message names the store and both versions.
- Allowed: the bundles swap by rename on the same volume, the build rolled back from is skipped until a newer one ships, and the app relaunches through the keep-terminals path (the older daemon adopts the hosts, or the rollback was refused because the host protocol is newer).
- Built: `cmux-tui __store-schemas [--stored]` prints what a build reads, or the newest schema each store holds in every session of the state root, read-only (workspace registry, conversation store). The app runs the kept bundle's own CLI when its Info.plist has no `CmuxStoreSchemas`, and the running bundle's CLI over both daemons' state roots (the app's and the Chief owner's), off the main actor. Entry point: `cmux app call updates.rollback '{}'` (`{"check": true}` only reports). A kept build that predates the probe is refused. Still open: the CLI verbs `cmux update check|install|status|channel|rollback` and a palette action.

## 2. Changelog

Each build publishes signed release notes next to the appcast (`notes/<version>.json`, Ed25519 content key in the `content-signing` environment; public key compiled into the app). Entries: highlights (Markdown, hash-pinned images/GIFs, a "Try it" action from an allow-list of action ids; the page never answers a confirmation) and fixes. A release that shows the what's-new card needs a human-written highlight file (`release-notes/next/<version>.md`); commit-subject notes go only to the full history. The page is React at `cmux-page://changelog`, cached offline.

## 3. Announcement cards

One Swift card stack in the sidebar (window-chrome exception), above the spaces dots, which sit directly above Settings (R112). Update-ready and what's-new cards always show; announcement cards show only on hover with the R100 footer. Small, one line, depth-stacked, expand on hover, x per card. Content: signed static feed `files-next.cmux.com/announcements/v1.json` (id, audience by channel and version range, start/expiry, actions), one conditional GET per update check with no identifiers. `announcements.enabled` hides them permanently; Settings and the palette "Show Announcements" bring them back; `announcements.fetch=false` stops all network use for them. Dismissals are local (daemon personal projection later).
