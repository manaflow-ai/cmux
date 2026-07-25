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

## 5. Open research variables (carried into DESIGN as claims-to-falsify)
- **R1 (load-bearing):** Does each CLI *persist* its refreshed token to a cmux-readable location
  (auth file / keychain), or keep it in memory only? Codex: yes (`last_refresh` in auth.json).
  Claude/Gemini/Kimi/Grok: **unverified.** Decides whether piggyback-freshness is viable per provider.
- **R2:** Do Grok/Kimi/Gemini expose a usage/limits endpoint at all? (Codex yes, Claude likely.)
- **R3:** What poll interval avoids anti-abuse (Codex 403'd on rapid repeat)?
- **R4:** Does refreshing rotate the refresh_token, per provider? (Only relevant if we ever add
  the optional in-memory-refresh path; default design avoids refresh entirely.)
- **R5:** Do any CLIs support multiple accounts/profiles, and where is that enumerated?
