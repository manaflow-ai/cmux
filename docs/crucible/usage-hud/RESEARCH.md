# RESEARCH — Multi-provider usage HUD

Verified 2026-07-23 (probe session). "Proven" = observed a live 200 this session.
"Plausible" = shape of the error implies the route exists. "Unknown" = not reachable yet.

## 1. Attribution machinery (already exists — reuse, don't build)
- `RestorableAgentKind` (`Sources/RestorableAgentTypes.swift:4`) — enum covers claude/codex/grok/
  gemini/kimi + more, with `displayName`, `rawValue`.
- Per-surface identity: `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID` injected into every PTY
  (`TerminalSurface.swift` ~L405). `VaultAgentProcessScanner.swift` buckets live agent processes
  back to `(workspaceId, surfaceId)`.
- Hook records at `~/.cmuxterm/<agent>-hook-sessions.json`
  (`RestorableAgentHookSessionRecord`) store `surfaceId → cwd → transcriptPath` directly.
- `SharedLiveAgentIndex.swift` — existing `@MainActor` singleton poller with a `DispatchSourceTimer`.
  **This is the architectural template for the new usage service.**
- Grep for `tokensUsed|costUsd|quotaRemaining|usageLimit` → **zero** agent-related hits. Greenfield.

## 2. Where limits live
- **Limits ("tokens left / reset") are ONLY behind provider APIs.** No CLI caches its quota to
  disk (checked codex logs sqlite, grok models_cache, kimi telemetry — none hold quota).
- **Local transcripts only yield tokens USED per turn** (Claude JSONL `message.usage`;
  Codex/Kimi session logs carry token events). Used only for the optional per-window column.

## 3. Provider endpoint matrix

| Provider | Endpoint | Auth source | Status | Notes |
|---|---|---|---|---|
| **Codex/ChatGPT** | `GET chatgpt.com/backend-api/codex/usage` | `~/.codex/auth.json` → `tokens.access_token` + header `chatgpt-account-id: tokens.account_id` | **PROVEN 200** | Returns `plan_type`, `rate_limit.primary_window {used_percent, limit_window_seconds:604800, reset_after_seconds, reset_at}`, `secondary_window`, `credits{has_credits,unlimited,overage_limit_reached,balance}`. **Repeated hits → 403 (anti-abuse). Cache + poll sparse.** |
| **Claude** | `GET api.anthropic.com/api/oauth/usage` (likely) | macOS Keychain service `"Claude Code-credentials"` → `claudeAiOauth.accessToken`; header `anthropic-beta: oauth-2025-04-20` | **Plausible** | Returned 401 (auth), not 404 (route). Token from disk was stale. Needs a fresh keychain token to confirm schema. |
| **Gemini** | Code Assist `cloudcode-pa.googleapis.com` | `~/.gemini/oauth_creds.json` → `access_token` (expiry_date ms) | **Unknown** | On-disk token was expired (~10.7h). Quota surface unconfirmed. |
| **Kimi** | base `api.kimi.com/coding/v1` | `~/.kimi/credentials/kimi-code.json` → `access_token` (`expires_at`) | **Unknown** | Token expired. `/users/me`, `/users/me/balance` → 404. Real usage route unknown. |
| **Grok** | base `cli-chat-proxy.grok.com/v1` | `~/.grok/auth.json` → `<issuer>.key` (818-char) | **Unknown / hardest** | "no auth context" with bearer — may need `x-xai-*` auth, not `Authorization: Bearer`. `/rate_limits`, `/usage` → 404 (nginx). Endpoint may not exist. |

## 4. Token freshness (the crux)
- On-disk tokens go stale; CLIs refresh in-memory / on-use. Confirmed expired at probe time:
  Gemini, Kimi, Grok. Codex worked only because it was fresh.
- **Rotation footgun:** if cmux runs a `refresh_token` grant and the provider rotates the
  refresh_token (single-use), the on-disk copy is invalidated → **user is logged out of their own
  CLI.** Therefore cmux must treat all auth files/keychain as **read-only**, never persist a
  rotated token.

## 4b. STEP-1 CLI USAGE-COMMAND CENSUS (2026-07-25) — the gate result

Dumped every CLI's full subcommand list. **The CLI-first path is mostly a mirage.**

| Provider | Non-interactive usage command? | Evidence |
|---|---|---|
| **Claude** | **No** | commands: agents/auth/auto-mode/doctor/gateway/install/mcp/plugin/project/setup-token/ultrareview/update. `/usage` is an in-session slash command, not a CLI subcommand. |
| **Codex** | **Unconfirmed** | real binary sits behind `cmux-codex-wrapper` shim; couldn't run headless. API endpoint `backend-api/codex/usage` is PROVEN regardless. |
| **Grok** | **No** | commands: agent/export/import/inspect/leader/login/logout/mcp/memory/models/plugin/sessions/setup/ssh/trace/update/version/worktree. None report quota. |
| **Kimi** | **No** | commands: login/logout/term/acp/info/export/mcp/plugin/vis/web. None report quota. |
| **Gemini** | **No** | commands: mcp/extensions/skills/hooks/gemma/query. None report quota. |

**Consequence:** the tempered "CLI-first, cmux never touches a token" core is unavailable for ~all
providers. Real build must use the **read-only-credential + direct-API path** (Temper's demoted
last resort) as the PRIMARY path, carrying all of Temper's hardening (F-T2/3/4) on the main line.
This does NOT reintroduce the rotation footgun (still never write/refresh a token), but it DOES put
credential-residency + anti-abuse + hostile-input on the main path. Fork surfaced to Nick.

## 4c. ENDPOINT CONFIRMATION ROUND (2026-07-25, fresh tokens where available)

| Provider | Token persists to disk? (R1) | Usage endpoint | Gauge feasible | Verdict |
|---|---|---|---|---|
| **Codex** | ✅ yes | `backend-api/codex/usage` | ✅ rolling window(s) + credits | **SHIP** |
| **Gemini** | ✅ yes (token was fresh 2d later) | `v1internal:loadCodeAssist` → 200 | ⚠️ account is `standard-tier` **"Unlimited"** — no numeric quota | **label-only** (show tier, no gauge) |
| **Grok** | ✅ yes (token fresh 2d later) | none found — proxy `/usage,/rate_limits,/me,/account` all 404; `grok.com/rest/rate-limits` 501 (maybe POST, needs web-session auth) | ❌ not with CLI token | **`.unsupported`** pending deeper discovery |
| **Kimi** | ❓ (token expired 15min ago) | unknown | ❓ | **needs 1 CLI run** to refresh, then probe |
| **Claude** | ❌ **NO** — keychain token 43 DAYS stale despite live session | endpoint likely exists but needs a live token; **no on-disk usage cache** (`policy-limits.json` is restriction policy, not quota) | ⚠️ blocked | **HARD** — headline provider, see below |

**Key positive:** Codex/Gemini/Grok all persist refreshed tokens to disk → read-only piggyback
works for them. **Claude is the lone exception** — Claude Code refreshes in-memory and never
rewrites the keychain item, so read-only piggyback yields a 43-day-stale token. Claude's live
"tokens left" therefore requires either (a) minting a fresh token from the keychain `refreshToken`
(rotation-footgun risk — must NOT test unilaterally), or (b) reading `anthropic-ratelimit-unified-*`
headers off a real `/v1/messages` call (needs a valid token AND burns quota). Both need a live token.

**Net achievable gauge today = Codex only.** Gemini = "Unlimited" label; Grok/Kimi/Claude blocked
or uncertain. This reshapes what "full 5" can mean — decision surfaced to Nick.

### Deep-discovery closure (2026-07-25, per Nick "discovery first")
- **Claude — DEAD END for live usage.** Keychain `refreshToken` is **empty** (only an expired
  accessToken remains); live creds are held by Claude Code's daemon (`daemon-auth-status.json:
  auth_required`, `authMethod: oauth_token`) / the ACL-locked "Claude Safe Storage" item. `claude
  auth status --json` returns only `{loggedIn, authMethod, apiProvider}` — no token, no usage, and
  does NOT refresh the keychain. The "use refresh_token" plan is **not executable**. Readable Claude
  signals: static `subscriptionType` + `rateLimitTier` (plan/tier) + local transcript burn only.
- **Grok — no usage route reachable with the CLI token.** Proxy paths 404; `grok.com/rest/rate-limits`
  is Cloudflare-blocked (403 1010) to the CLI bearer (needs a browser/web session). `.unsupported`.
- **Kimi — still pending** one `kimi info` run to refresh its token before it can be probed.

**FINAL discovery verdict:** only **Codex** exposes a live "tokens-left" gauge. Realistic HUD shape
= Codex gauge + universal local **burn** layer (transcript `message.usage`, zero-credential, works
for every provider) + static plan/tier labels where readable (Claude Max, Gemini Unlimited).

### 4d. CLAUDE SOLVED (2026-07-25) — supersedes the "Claude blocked" verdict
Claude Code authenticates via the **`CLAUDE_CODE_OAUTH_TOKEN` env var** (a `claude setup-token`,
long-lived ~1yr, **non-rotating** → zero risk), NOT the stale keychain. `claude auth status --text`
reveals this. The token is `user:inference`-scoped, so `/api/oauth/usage` + `/api/oauth/profile`
403 (need `user:profile`) — BUT the usage data rides on **response headers of a real `/v1/messages`
call**, which only needs `user:inference`:

```
POST https://api.anthropic.com/v1/messages   (model: claude-haiku-4-5-20251001, max_tokens:1)
  Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN
  anthropic-beta: oauth-2025-04-20
→ 200, headers:
  anthropic-ratelimit-unified-5h-utilization: 0.07   anthropic-ratelimit-unified-5h-reset: <epoch>
  anthropic-ratelimit-unified-7d-utilization: 0.59   anthropic-ratelimit-unified-7d-reset: <epoch>
  anthropic-ratelimit-unified-5h-status/7d-status: allowed
  anthropic-ratelimit-unified-representative-claim: five_hour
```
So **Claude = full gauge (5h + weekly utilization + reset).** Cost: ~1 token/poll (a real inference
call), so poll on-demand + cache only; the probe itself nudges utilization negligibly. `count_tokens`
does NOT carry these headers — must be `/v1/messages`.

**Updated scorecard: Claude ✅ + Codex ✅ (both full gauges), Gemini = Unlimited (no quota exists),
Grok = unsupported via CLI token, Kimi = pending one `kimi info` refresh.**

### 4e. GROK SOLVED (2026-07-25) — same inference-header pattern as Claude
Grok's proxy gates inference on a **`x-grok-client-version`** header (426 without it; header name
found via `strings ~/.grok/bin/grok`). With it, a minimal responses call returns usage in headers:

```
POST https://cli-chat-proxy.grok.com/v1/responses   {model:grok-4.5, input:"hi", max_output_tokens:1}
  Authorization: Bearer <auth.json .key>
  x-grok-client-version: 0.2.22        (also seen: x-grok-user-id, x-grok-client-identifier, x-grok-deployment-id)
→ 200, headers:
  x-ratelimit-limit-tokens: 53000000    x-ratelimit-remaining-tokens: 53000000
  x-ratelimit-limit-requests: 8300      x-ratelimit-remaining-requests: 8300
```
So **Grok = gauge** (tokens + requests remaining/limit; no reset epoch in these headers → show % used,
not countdown). Cost: 1 minimal inference call per poll → on-demand + cache.

### THE REUSABLE KEY
Usage lives in the **response headers of a real inference call**, not a dedicated usage endpoint,
for Claude (`anthropic-ratelimit-unified-*`) and Grok (`x-ratelimit-*`). Codex has a real usage
endpoint. Kimi almost certainly follows the inference-header pattern too (verify after `kimi info`).
Design implication: adapters need an "inference-probe" mode (minimal call, read headers, discard body)
in addition to the "usage-endpoint" mode — both are on-demand + cached (each probe costs ~1 token).

### FINAL SCORECARD (2026-07-25)
| Provider | Gauge | Source | Cost/poll |
|---|---|---|---|
| **Claude** | ✅ 5h + weekly % + reset | `/v1/messages` unified headers, `CLAUDE_CODE_OAUTH_TOKEN` | ~1 token |
| **Codex** | ✅ window + credits | `backend-api/codex/usage` endpoint | free (throttled) |
| **Grok** | ✅ tokens + requests remaining | `/v1/responses` `x-ratelimit-*` headers | ~1 token |
| **Gemini** | — (Unlimited tier) | `loadCodeAssist` (label only) | free |
| **Kimi** | ❓ pending refresh | likely inference headers | TBD |

## 5. Open research variables (carried into DESIGN as claims-to-falsify)
- **R1 (load-bearing):** Does each CLI *persist* its refreshed token to a cmux-readable location
  (auth file / keychain), or keep it in memory only? Codex: yes (`last_refresh` in auth.json).
  Claude/Gemini/Kimi/Grok: **unverified.** Decides whether piggyback-freshness is viable per provider.
- **R2:** Do Grok/Kimi/Gemini expose a usage/limits endpoint at all? (Codex yes, Claude likely.)
- **R3:** What poll interval avoids anti-abuse (Codex 403'd on rapid repeat)?
- **R4:** Does refreshing rotate the refresh_token, per provider? (Only relevant if we ever add
  the optional in-memory-refresh path; default design avoids refresh entirely.)
- **R5:** Do any CLIs support multiple accounts/profiles, and where is that enumerated?
