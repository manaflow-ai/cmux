# DESIGN — Multi-provider AI-usage HUD

## Problem
cmux runs up to five different agent CLIs side by side, but a user cannot see how much of each
provider's rolling quota they have left or when it resets until an agent hits a wall mid-task.
Provide an in-app HUD: a compact footer readout for the active provider + a multi-account panel
across all providers, showing % used / tokens or credits left / time-to-reset for each account's
rolling windows.

## DECISION (2026-07-25, Nick)
Step-1 census found **no CLI exposes a non-interactive usage command** (RESEARCH §4b), so the
CLI-first core is unavailable. Nick chose **"hardened direct-API, all 5"**: the read-only-credential
+ direct-API path is now the PRIMARY line for every provider, carrying the full Temper hardening
(F-T2/3/4) on the main path. `ProviderCredentialReader` is therefore a CORE component, not a
last-resort. Invariant unchanged: cmux never refreshes/writes a token. The second cross-family strike
(pre-merge gate) matters MORE under this decision because the credential surface is now core.

## Core principle (superseded by DECISION above for path selection; hardening still applies)
**cmux never handles credentials and never runs a background poll. It asks each CLI to report its
own usage, on demand.** The primary and default-only path is to invoke each provider CLI's
**non-interactive usage subcommand** (e.g. `codex usage --json`) when the user opens the panel or
switches the active provider. The CLI owns its entire auth lifecycle — it refreshes its own token,
attributes the call to itself, and cmux never reads, holds, or writes a token.

Precise invariant (Temper F-T1 fixed the sloppy version): **cmux itself never performs a token
refresh and never writes a token.** A CLI that cmux *invokes* may refresh its OWN token as a side
effect of doing its job — that is the tool managing its own credential, not cmux touching auth.
The forbidden thing is cmux running an OAuth `refresh_token` grant or writing an auth file; spawning
`codex usage` is not that.

**The credential-reading + direct-API path is demoted to a default-OFF, hardened last resort**
(Temper F-T2/F-T5), used only for a provider that has *no* machine-readable usage command AND a
documented usage endpoint AND an honest (non-impersonating) client identity. It is opt-in per
provider, never default.

Consequence, stated honestly: usage is shown **on demand**, not live-ticking; between fetches the
tile shows last-known + age. A provider whose CLI can't report non-interactively (would prompt
login) shows `resume <agent> to refresh`, never triggers an interactive prompt.

## Architecture

New macOS-only package **`Packages/macOS/CmuxUsage`** (these CLIs don't run on iOS).

```
CmuxUsage
├─ Model/
│   ├─ UsageSnapshot.swift      // immutable value type (Sendable)
│   ├─ UsageWindow.swift        // .rolling(seconds), usedPercent, resetAt, limit?
│   ├─ ProviderAccount.swift    // provider + accountId + displayName + freshness
│   └─ UsageFreshness.swift     // .live(Date) | .stale(lastKnown?) | .signedOut | .unsupported | .rateLimited(until:)
├─ Auth/
│   └─ ProviderCredentialReader.swift   // READ-ONLY: parse auth files / keychain; compute token exp; never writes
├─ Adapters/
│   ├─ ProviderUsageAdapter.swift       // protocol: fetch(account) async throws -> UsageSnapshot
│   │                                   // TWO MODES (Fold F5): .cliSubcommand (preferred) | .directAPI (fallback)
│   ├─ CodexUsageAdapter.swift          // PROVEN
│   ├─ ClaudeUsageAdapter.swift
│   ├─ GeminiUsageAdapter.swift
│   ├─ KimiUsageAdapter.swift
│   └─ GrokUsageAdapter.swift
└─ UsageIndex.swift             // @MainActor singleton poller (DispatchSourceTimer), publishes snapshots
```

### Data shapes
```swift
struct UsageWindow: Sendable, Equatable {
    enum Kind: Sendable { case rolling(seconds: Int); case credits }   // 18000=5h, 604800=7d
    var kind: Kind
    var usedPercent: Double?      // 0…100, nil if provider only gives credits
    var resetAt: Date?
    var creditsRemaining: Double? // for the credits kind
}
struct UsageSnapshot: Sendable, Equatable {
    var account: ProviderAccount
    var planLabel: String?        // "plus", "max", …
    var windows: [UsageWindow]
    var freshness: UsageFreshness
    var fetchedAt: Date
}
```

### UsageIndex (on-demand fetcher — REVISED after Temper, no background poll)
- `@MainActor final class UsageIndex` with `static let shared`, modeled on `SharedLiveAgentIndex`.
- Holds `private(set) var snapshots: [AccountKey: UsageSnapshot]` where `AccountKey = provider+accountId`.
- Publishes an **immutable dictionary snapshot**; UI reads value copies only.
- **No background timer by default.** Fetch is triggered by explicit user action: panel open, or the
  active provider changing. Result is cached with `fetchedAt`; the tile shows last-known + age. A
  manual tap re-fetches. Per-provider floor (e.g. one fetch / 30s) to avoid hammering; backoff +
  `.rateLimited(until:)` on any 429/403. This eliminates the anti-abuse surface the poller created.

### Credential reader (LAST-RESORT ONLY — built only if step 1 requires it; READ-ONLY, security-critical)
- Parses `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`, `~/.kimi/credentials/kimi-code.json`,
  `~/.grok/auth.json`; reads Keychain `"Claude Code-credentials"` via Security framework.
- Decodes the JWT `exp` (or file `expires_at`) to compute freshness **without a network call**.
- **Invariants:** opens files O_RDONLY; never writes; never logs a token; tokens live only in
  memory for the duration of a request; not included in any debug dump or crash report.

## UI

### Footer tile (`UsageFooterTile`)
- Inserted in `SidebarFooterButtons` HStack (`ContentView.swift:14295`), after the `?` button.
- Shows the **active surface's** provider: a compact pill, e.g. a small ring at `usedPercent` +
  `"3h12m"` to reset. `.signedOut`/`.unsupported` → tile hidden for that provider.
- **Snapshot-boundary compliance:** the footer HStack is a fixed row, not inside a
  `LazyVStack`/`List`, so observing a small store here is allowed — BUT to stay off the typing
  hot path, the tile receives a **precomputed immutable `UsageTileModel` value** (not the store),
  recomputed only when the active provider's snapshot changes (Equatable-gated), never in `body`.
  Zero allocations/formatting on the render path; strings formatted on snapshot change.
- Tap → opens the multi-account panel via `ArrowlessPopoverAnchor` (same mechanism as the help button).

### Multi-account panel (`UsageLimitsPanel`)
- Reached two ways (shared action path — cmux-shared-behavior law): (1) tapping the footer tile,
  (2) a new "Usage limits" item in the existing help/footer menu (`SidebarHelpMenuButton` popover).
- One row per provider account: provider icon + displayName + plan label + a bar per window
  (5h / weekly) with % + reset countdown + credits line where present. Freshness badge per row
  (`live` / `stale` / `signed out` / `rate-limited` / `not supported`).
- If a list/scroll is used, rows get immutable value snapshots + closure bundles only
  (`IndexSectionActions` pattern) — no store reference below the boundary.

## Build order (REVISED after Temper — CLI-capability first, credentials last)

1. **CLI usage-command census (R6 — the new gate, no credential code).** For each of the five CLIs,
   determine empirically whether it exposes a **non-interactive, machine-readable usage command**
   that runs without prompting and reports quota (probe `codex usage --json`, `grok`/`kimi`/`gemini`
   equivalents, `claude` usage surface). Output a capability table: provider → {cli-usage-command |
   none}. **This gates the architecture per provider**: has-command → CLI-first path (no tokens);
   none → candidate for the default-off direct-API last resort (or `.unsupported`).
2. **CodexUsageAdapter via its resolved path + on-demand fetcher.** Wire the fetcher (on-demand, no
   background poll), cache with age, hostile-input parsing (strict schema, fail-closed). Note: the
   cmux CLI-shim scrubs env — resolve the real CLI binary path, don't rely on a shimmed `PATH`.
3. **Footer tile for the active provider** (Codex first) + localization (en + ja). Tile shows
   last-known + age; tap refreshes.
4. **Multi-account panel** (Codex only initially) + the help-menu item + shortcut policy wiring.
   Panel-open triggers an on-demand refresh.
5. **Remaining providers, one PR each, per-provider flagged, CLI-path preferred:** Claude → Gemini →
   Kimi → Grok. A provider with no CLI usage command and no honest direct endpoint ends
   `.unsupported` — an honest outcome, not a failure.
6. **Credential-reading direct-API last resort (build ONLY if step 1 leaves a wanted provider with
   no CLI command).** Default-off, per-provider consent, hardened per the blast-radius section. If
   step 1 shows every wanted provider has a CLI command, `ProviderCredentialReader` is **never built**.
7. **(Optional) per-window tokens-USED column** from transcripts, reusing the existing
   window→transcript mapping.

## Blast radius & consent spine (REVISED after Temper — cage before monster)
- **Hostile input, not "no attack surface" (F-T3).** Auth JSON, keychain blobs, CLI stdout, and
  usage API response bodies are ALL untrusted input parsed inside a process. Treat every one as
  hostile: strict Codable schemas, bounded sizes, fail-closed on any drift, no code path driven by
  payload shape. The earlier "no external-input attack surface" claim was wrong and is retracted.
- **Credential residency is the worst-case blast radius (F-T2).** A process holding several CLIs'
  OAuth tokens is a single point of multi-account takeover (RCE / plugin surface / crash dump).
  Mitigation, in priority order: (1) **CLI-first path holds NO tokens at all** — this is why it's
  the core; (2) the last-resort direct-API path, where used, minimizes residency (one provider at a
  time, dropped immediately after the request), is per-provider consented, and is **excluded from
  the extensions/debug/crash-dump surface** entirely.
- **Anti-abuse: no background poll, no UA spoofing (F-T4).** Fetch only on explicit user action
  (panel open / active-provider switch), via the CLI-attributed path. Never forge a CLI's
  User-Agent — that's client impersonation/evasion, not mitigation. The direct-API last resort uses
  an honest cmux identity and is default-off with the rate-limit risk documented.
- **Feature-flagged** globally + per provider; CLI-path providers can default-on (no token, no
  poll); direct-API providers default-OFF.
- **cmux never runs a token refresh and never writes an auth file/keychain item** — enforced by
  there being no such code path; a CLI cmux spawns managing its own token is out of scope of this
  invariant (F-T1).

## Claims to falsify (hand these to Temper)
- **C1 (load-bearing):** Each CLI persists its refreshed token to a cmux-readable location, so
  read-only piggyback sees fresh tokens. *If false for a provider → that provider is stale-only or
  unsupported.* (Codex ✓; others unverified — gated by build step 1.)
- **C2:** Grok/Kimi/Gemini expose a usable limits endpoint. *If false → `.unsupported`, HUD shrinks
  to the providers that do (Codex + Claude at minimum).*
- **C3:** A ≥60s sparse poll avoids anti-abuse across all providers. *If false → longer intervals or
  event-driven-only refresh.*
- **C4:** The footer HStack is safe to host a live-updating tile without touching typing latency.
  *If false → move the tile or make it fully static + tap-to-refresh.*
- **C5:** "One account per provider" is an acceptable v1 for a feature explicitly sold as
  "multi-account." *If false → must discover multiple profiles per CLI in v1 (R5).*
- **C6:** Reading the Claude keychain item from the cmux app process actually succeeds (keychain
  ACLs may scope the item to the Claude Code binary only). *If false → Claude becomes stale-only or
  needs a different source.*

## Rejected alternatives
- **Trawl transcripts for everything.** Rejected: transcripts have tokens *used*, never *limits/left*.
- **cmux refreshes tokens itself.** Rejected: rotation footgun logs the user out of their own CLI.
- **Standalone menu-bar / ccusage-style external tool.** Rejected: not in the one pane that sees all
  five agents; Nick wants it in the footer.
- **Aggressive real-time polling.** Rejected: Codex 403'd on rapid repeat; anti-abuse risk to the
  user's account.
- **Ship all five at once, big-bang.** Rejected: only Codex is proven; per-provider PRs let the HUD
  ship value while unknown endpoints are still being confirmed.

## Fold — author self-pass (folded back into this design)

Struck the casting myself before Temper. Material findings, folded in:

- **F5 (biggest — reshapes the adapter).** I under-evaluated the "shell out to the CLI's own usage
  command" alternative. Where a CLI exposes a **non-interactive machine-readable usage subcommand**
  (e.g. `codex usage --json`), that path is *strictly safer* than a direct API call: it sidesteps
  keychain/auth-file reading (kills C6), token-freshness (kills C1), AND anti-abuse (it IS the CLI's
  own attributed call, not a second client on the same token). So the adapter is now **two-mode**:
  prefer `.cliSubcommand`, fall back to `.directAPI` only where no such command exists. New research
  var **R6: does each CLI expose a non-interactive usage command?** — checked in build step 1
  alongside R1. This may make the credential-reader unnecessary for some providers entirely.
- **F1 (anti-abuse is under-counted).** cmux's own API calls (directAPI mode) add request volume to
  the user's account under a *different* User-Agent than the CLI — providers may flag mismatched-UA
  or two-client patterns (Codex 403 already showed sensitivity). Mitigation folded in: directAPI
  mode mimics the CLI's real UA/headers, polls ultra-sparse, and `.cliSubcommand` mode is preferred
  precisely because it avoids this. Anti-abuse is now a **named owned risk**, not "harmless."
- **F7 (lifecycle gating).** Poller runs **only when the app is active** and the footer tile is
  visible or the panel is open. No polling while backgrounded — saves quota-attributed calls and
  shrinks the anti-abuse surface.
- **F4 (observation isolation, sharper).** The 90s publish must invalidate **only the leaf tile**,
  never a parent containing the workspace list / any `LazyVStack`. The panel is popover-mounted
  (exists only while open), so its updates never touch the sidebar tree. A 90s tick is far below
  typing frequency, but misplaced observation could still thrash the list — so the store is observed
  at the tile leaf via a derived Equatable value only.
- **F2/F3 (active-provider + credits-only rendering).** Active provider = most-recently-focused
  surface with a detected agent (from the live agent index); tile hidden if none. Tile renders a
  ring when `usedPercent != nil`, else a compact credits-remaining number — providers differ
  (window-only, credits-only, or both, like Codex).
- **F8 (no high-frequency timer).** Reset countdown renders coarse ("3h" / "12m"), recomputed on the
  90s poll tick — never a 1Hz timer in the footer (typing-latency law).
- **F6 (absent vs signed-out).** No auth file at all → provider `.notInstalled` → hidden entirely;
  distinct from `.signedOut` (installed, token gone).

Fold did **not** re-grade the ore (candidate fixed at consent) and does **not** replace Temper —
same-distribution blindness means the cross-family strike still has to happen.

## Temper — cross-family strike record (2026-07-25)

**Adversary reached:** Grok / xAI (Tesla) — a genuine different-family strike, not a persona.
Codex, Gemini, Kimi were not drivable non-interactively from the scrubbed cmux shell this session
(codex shim couldn't resolve its binary; gemini blocked on interactive auth; kimi CLI syntax).

**Verdict: design re-cast (round 1 of ≤3), not invalidated.** Grok's five findings were decisive
and convergent — all pointing at "you centered the credential-reading poller; center the CLI's own
usage command instead." Folded back:
- **F-T1 (fatal):** "cmux never writes" was violated by the preferred CLI-spawn path → invariant
  re-stated precisely (cmux never refreshes/writes; a CLI it spawns managing its own token is fine).
- **F-T2 (fatal):** multi-token residency = single point of multi-account takeover → CLI-first path
  holds no tokens; direct-API residency minimized, consented, excluded from extension/crash surface.
- **F-T3 (fatal):** "no external-input attack surface" retracted → all parsed I/O treated hostile.
- **F-T4 (fatal):** UA-mimic is evasion → no background poll, no UA spoofing, on-demand only.
- **F-T5 (fatal):** simpler alternative (CLI `usage --json` on demand) wins → it is now the core;
  credential reader demoted to a may-never-build last resort.

**Honesty label:** TEMPERED by **one** genuine cross-family adversary, not the full five-cast. This
is stronger than a persona-only pass (a real different inductive bias struck and its findings
reshaped the design) but weaker than a full cast. **Required gate before merge:** a second
cross-family strike (Codex/GPT + Gemini) on this revised design, run from an environment where those
CLIs are drivable — the F-T1 CLI-spawn invariant and the hostile-input parsing especially want a
second bias. This is carried into the Blade plan as a pre-build gate.

## Open variables (no silent TODOs)
- Exact Claude `oauth/usage` response schema (needs a fresh keychain token).
- Whether Gemini/Kimi/Grok have any limits endpoint (R2/C2).
- Multi-account enumeration mechanism per CLI (R5/C5).
- Final poll interval per provider (R3/C3).
- Default-on vs default-off at GA.
