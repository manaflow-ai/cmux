# Local CodeRouter design (cmuxterm-hq-5c, lane agents/acpmux)

I did not edit any file. This report uses origin/feat-cmux-next at 2a6f4b115dfb.

## Facts
1. The hosted coderouter is TypeScript in `web/`. The data plane is in `web/app/v1/{messages,responses,codex/responses,models}` and `web/services/coderouter/{claudeProxy,codexProxy,opencodeProxy,capacityHold}.ts`. The ledger is ClickHouse `route_events` and `usage_events`. The Rust `cr` (~/fun/coderouter) is only a CLI client. It does not route traffic.
2. The hosted VMs get their endpoint from `vmGuestEnv.ts`: `OPENAI_BASE_URL=<origin>/v1`, `ANTHROPIC_BASE_URL=<origin>`, and a placeholder key. This proves that Codex and Claude Code work through a plain env base URL.
3. Today, acpmux routes Claude through the subrouter only as a fallback. `config.rs` near line 773 sets `ANTHROPIC_AUTH_TOKEN=subrouter`. `session_env.rs` refuses `*_BASE_URL`, `CODEX_HOME` and `HOME` from clients, which is correct.
4. `cmux-local-auth` already has a Host check, an Origin check and a constant-time token compare (`ListenerPolicy`, `tokens_match`). The lockfile already has axum, hyper, rustls, reqwest and security-framework.
5. The app replaces a stale daemon in `AcpmuxVersionHandoff.swift`: it compares the build, sends SIGTERM, and agent hosts survive. The repo has no fd passing (no SCM_RIGHTS) and no Sentry in the Rust crates.
6. The Seatbelt profile `sandbox/remote-chain.sb` blocks all loopback traffic except `@API_PORT@`. That is the port of a loopback `ANTHROPIC_BASE_URL`.
7. The Swift side has Settings > Accounts (`CmuxNextAccounts`, one card per provider group, a cmux sign-in banner) and `ProviderKeyStore` (Keychain). There is no Settings > Agents section. The model picker is in `webviews/src/agent-session/acpmux/ModelPicker*.tsx`.
8. Subrouter bugs from memory:
   - Sticky overload loop: the sticky key is remote address + user agent, and the router does not read `response.failed`.
   - Live debit floor: `score()` floors at 1%, so it cannot be used for eviction.
   - A restart closed port 31415 for 80 s.
   - Refresh tokens died with `refresh_token_reused` because two clients shared one login.

## A. Location and updates
- Create the crate `cmux-tui/crates/cmux-coderouter` as a library. acpmux links it and runs it with `acpmux router serve`. This is a separate process from the same binary. So there is one version, one signed artifact and no new bundle entry.
- The daemon starts the router detached, the same way it starts agent hosts. A daemon restart therefore does not stop model streams that are in progress.
- On an update, `_acpmux/status` shows `routerBuild`. When it is not the daemon's build, the daemon starts the new router with `--takeover`. The old router sends its listen sockets over the router UDS (SCM_RIGHTS), stops `accept`, and drains its streams for at most 15 minutes. The port never closes (the subrouter lesson).
- Paths: `<ACPMUX_HOME>/router/` (mode 0700) holds `router.sock` (0600), `config.json` (account ids, labels, priority, paused, policy; no secrets) and `state.json` (cooldowns, usage cache, port). A tag teardown and the `agent_host` sweep also end the router, through its record and lock.
- Migration: import nothing automatically. The CLI logins (`~/.claude`, `~/.codex/auth.json`) stay the user's own. Copying their refresh tokens causes reuse races. The legacy `~/.subrouter` accounts are dead, so the design ignores them.
- Objection: "Takeover by fd passing is new and difficult. A library inside the daemon is simpler." Answer: then each update cuts the streams of agents that survive the restart.

## B. Accounts and routing
- The account kinds are: Claude OAuth, Claude setup-token (1 year, the recorded subrouter default), Anthropic API key, Codex ChatGPT OAuth, OpenAI API key, and the hosted coderouter (`crk_` key).
- Secrets: the router alone owns one Keychain generic-password item per account. The service is `com.cmuxterm.coderouter[.<tag>]` and the account field is the `acct_` handle. The item is "this device only". The ACL is the designated requirement (identifier + team, not cdhash), so an update does not cause a prompt.
- Swift and the UI never read secrets. A secret never goes into a harness env.
- OAuth:
  - Codex uses PKCE with the 127.0.0.1:1455 callback. The router runs the callback for the login only.
  - Claude uses PKCE with a code paste (the existing `PasteField`).
  - Refresh is single-flight per account. The router writes the rotated refresh token to the Keychain before it uses the new access token.
- Health: each account has one of the states active, cooling, exhausted, expired, broken or paused. Usage comes from:
  - Claude: `/api/oauth/usage` for OAuth accounts; rate-limit headers or a probe for setup tokens.
  - Codex: the usage endpoint or the response headers.
- Routing:
  - Each scoped key is one session, so the session is the sticky key. This removes the address+UA bug.
  - Before the first byte, a 429, 529, 5xx or SSE overload causes a cooldown (`retry-after`) and a retry on the next account.
  - A mid-stream overload goes to the client unchanged, and the router removes the sticky pin. The next retry then goes to a different account (the loop fix).
  - Eviction and refusals use measured headroom only. The debited estimate only orders new picks (the floor fix).
  - A new session takes a weighted spread in the highest priority tier. A sticky session moves only on a failure or when another account has 10 points more headroom (prompt cache).
- Objection: "Router-owned legacy-Keychain items with unsigned DEV tags will prompt or fail." Answer: each tag uses its own service. DEV prompts are acceptable.

## C. Security (includes R1 to R4)
- Bind: the router UDS (`router.sock`) carries all admin calls. The data plane is on loopback TCP, because Claude Code, Codex and OpenCode accept only an http base URL.
- The bind type is a `LoopbackAddr` newtype that cannot hold 0.0.0.0 or `::` (R1). A test checks that.
- Every TCP request gets these checks through `cmux-local-auth`:
  - Host must be `127.0.0.1:<port>` or `localhost:<port>`; else 421.
  - Any `Origin` header gets 403, so no origin is allowed.
  - `OPTIONS` gets 403 and the router sends no CORS headers.
  - `GET` is allowed only on `/v1/models` and has no side effects.
  - Limits: body 64 MiB, headers 64 KiB.
- Keys (R2): the format is `crl_<installId>_<keyId>_<32-byte secret>`.
  - The router keeps only HMAC(installSecret, secret).
  - acpmux mints one key per session over the UDS. The key carries a scope (harness, session, surfaces, expiry). acpmux revokes it at the end of the session. Rotation is a revoke plus a new mint.
  - A key with another installId, or with an HMAC that does not match, gets 401 (R4).
  - The router never sends the client's auth header upstream.
- Logs (R3):
  - The request log keeps only request id, account handle, model, status, tokens and latency. It has no headers and no bodies.
  - `Secret<T>` is a zeroizing newtype whose Debug prints `<redacted>`.
  - The panic hook writes only the file and line. It discards the payload.
  - At start, the router sets `RLIMIT_CORE=0`. macOS `.ips` reports contain no heap. There is no Sentry. If a later change adds Sentry, it needs a `before_send` scrubber and a test.
- Remote (Web and peer) sessions run their harness on this Mac with a `remote`-scope key. Only the router holds account tokens. Web clients get only redacted labels. A peer Mac uses its own router, and no router accepts cross-machine traffic.
- Sandbox: the router TCP port becomes the `ANTHROPIC_BASE_URL` port. So the existing `@API_PORT@` rule is the allowed path, and the profile needs no new hole. The spawn canary must probe a different acpmux port.
- Objection: "Malware that runs as the same user can read the harness env and use the key." Answer: a key works only from loopback, only for its own session, and only until revocation. Codex also gets `shell_environment_policy.exclude` for the key variable.

## D. ACP transparency
- `hub/spawn.rs` adds the route env when the router has a usable account for the family and the profile sets no user base URL or auth env. The router computes this env, never the client, so `session_env` `ALLOWED_KEYS` stays unchanged.
- Per harness:
  - claude: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=<key>`. Remove `ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN`.
  - codex: `OPENAI_BASE_URL=.../v1`, `OPENAI_API_KEY=<key>`. The router maps `/v1/responses` to the Codex backend, as the hosted coderouter does.
  - opencode: a generated `OPENCODE_CONFIG` file in the session folder.
  - pi: test it first. If it fails, use passthrough.
  - gemini and aider: passthrough.
- The fingerprint in `hub/pool/auth.rs` adds the route generation. Replace the `subrouter` fallback in `config.rs` with this route.
- Models: `/v1/models` returns the union of the models of the usable accounts. The router sends a model only to accounts whose plan has it.
- In the picker, model ids stay the same. `_meta.cmux.router {accounts, healthy}` adds a small "Pool 3/4" mark. "Auto" is the default. A per-session account pin goes through `_acpmux/router.pin`.
- With no accounts: no route env, so the harness uses the user's own login, as it does today.
- Objection: "API-key mode changes the Codex UX (auth status, the ChatGPT-only features)." Answer: the hosted VMs already run this way.

## E. UI
- Settings > Accounts gets one compact list, "Model accounts", with 28 pt rows:
  - provider mark, label, plan chip, health dot, usage bar (worst window) and a drag handle;
  - a context menu with Pause, Sign in again, Rename and Remove;
  - a "+" menu with Claude (sign in, setup token, API key), Codex (ChatGPT, API key) and CodeRouter team.
- The cmux sign-in banner moves into the CodeRouter team row.
- The agent pane gets a status chip next to the model picker, with a popover.
- The app reaches the router through `_acpmux/router.*` on the daemon UDS. `remote_guard` refuses Web and peer callers, and the Web origin gets a read-only, redacted list.
- Files to change:
  - `Packages/macOS/CmuxNext/Sources/CmuxNextAccounts/{AccountsModel,AccountsPageState,AccountsServices,MockAccountsServices,AccountsStrings}.swift`
  - `Packages/macOS/CmuxNext/Sources/CmuxNextAccounts/Views/{AccountsSectionView,AccountRowView}.swift`
  - `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Accounts/AccountsService.swift`
  - new: `CmuxNextCodeRouter/Local/LocalRouterClient.swift`
  - `webviews/src/agent-session/acpmux/{ModelPicker,ComposerPickers,modelMenuNodes}.tsx`
- Objection: "Drag priority is clutter for most users." Answer: the handle shows only on hover.

## R5. Shared shape with lane hq-ff
hq-ff must agree on these fields and names:
1. One provider enum that adds `claude-oauth`, `claude-setup-token` and `anthropic-apikey`. Today Claude is in a separate table.
2. `id` as an `acct_` handle, plus `label` and `visibility`.
3. `state` {active, refreshing, expired, broken}, plus local-only `paused` and `cooling`.
4. `credentialExpiresAt`, `cooldownUntil`, `activeSessions`.
5. `lastFailureCode`, with one shared code vocabulary.
6. `quotaWindows[] {window: "5h"|"7d"|"weekly", usedPercent (measured only), resetsAt, source, measuredAt}`.
7. The `x-coderouter-request-id` header.
8. The model catalog item shape.

Locally, the hosted coderouter is one account, after the local accounts in the failover order. Objection: "A shared schema couples the release order of the two lanes." Answer: use contract fixture JSON on both sides.

## F. Phases (each phase writes red tests first)
1. Crate, `acpmux router serve`, listeners, security gate, keys. Red tests: Origin, Host rebinding, foreign key, `LoopbackAddr`, OPTIONS, body limit. Needs the main WINDOW (new member, Cargo.lock, acpmux Cargo.toml; add all dependencies now). Gates: Testbox, plus the Windows jobs (the crate uses `cfg(unix)`).
2. Keychain store behind a trait, `config.json`/`state.json`, redaction, panic hook. Red tests: no secret in Debug, logs or a panic. The Keychain test runs on a fleet Mac (headless). WINDOW-LITE.
3. Messages and Responses forwarding, SSE passthrough, auth swap, upstream header timeout. Gate: Testbox with a mock hyper upstream.
4. Routing policy. Red tests replay the sticky-loop, mid-stream-overload and debit-floor bugs. Gate: Testbox.
5. OAuth, refresh single-flight, usage polling, with fake token endpoints. Gate: Testbox.
6. acpmux integration: start the router, `routerBuild`, takeover and drain, route env per harness, pool fingerprint, sandbox port. Gates: Testbox, plus the sandbox canary on a fleet Mac. This phase needs a WINDOW only if it changes the protocol spec or the schema (`acpmux-schema.json`).
7. Swift UI. Gates: compile with `nx-remote --host cmux-mini-6 --xcode 26.6`; Swift and GUI tests on cmux-lawrence-2.
8. Webviews picker mark and status chip. Gate: the webviews checks (bun test, typecheck, biome).
9. Hosted upstream account and the hq-ff contract fixtures.

## Decisions for Lawrence
1. Legal and money: the router pools many consumer Claude and ChatGPT subscriptions with the CLIs' own OAuth client ids. Both providers' terms can restrict this.
2. Taste: there is no Settings > Agents section. Use Settings > Accounts (my default), or add a new Agents section.
3. Taste: does a priority drag mean strict fill-first, or a spread inside each tier (my default)?

### Critical Files for Implementation
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/Cargo.toml (workspace members; needs the WINDOW)
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/crates/acpmux/src/hub/spawn.rs (route env at spawn)
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/crates/acpmux/src/config.rs (replace the subrouter fallback near line 773)
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/crates/cmux-local-auth/src/lib.rs (Host, Origin and token checks to reuse)
- /Users/lawrence/fun/cmuxterm-hq/repo/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxVersionHandoff.swift (update handoff; add the router build)

## Lead decisions (hq-5c, 2026-10-07)
- UI home: Settings > Accounts ("Model accounts"), matching the Settings redesign P2 category Accounts.
- Priority: spread inside each priority tier (not strict fill-first).
- Pooling consumer subscriptions: legal question for Lawrence; phases 1-4 (security core, keys, forwarding, routing with API-key accounts) do not depend on it.

## Chief rule (2026-10-07)
OAuth account pooling (several consumer Claude or ChatGPT logins) stays behind a flag, OFF by default, until Lawrence answers the legal question. API-key accounts and one personal login per provider are not affected.

## Lawrence decision (2026-10-07, via chief), replaces the OFF-by-default flag
"yes by default, it will run on user's own computer, we need to get to subrouter parity in terms of logic and everything, but in rust https://github.com/manaflow-ai/subrouter"
- Pooling of the user's OWN Claude and ChatGPT subscriptions is ON by default, no flag gate. Local only; credentials in the user's Keychain; they never leave the machine. Never pool accounts of different users.
- Target: logic parity with subrouter (account selection and scoring, capacity and overload handling, sticky sessions, retries, refresh, cache economics), in Rust. A parity matrix (feature -> subrouter file -> Rust module -> test) goes into plans/cmux-next/local-coderouter.md before phase 2.

## Parity matrix adopted (2026-10-07)
parity-matrix.md (123 rows, subrouter origin/main 44cb715) is the behavior source. Where it differs from this plan, the matrix wins, except in the 10 rows that would copy a known bug: those use the corrected behavior in the matrix. Main changes to this plan:
- Codex does not read OPENAI_BASE_URL for its built-in provider: acpmux gives Codex a custom model_provider (supports_websockets=true) that points at the router.
- Claude 529 and 5xx: wait on the same account (keeps the prompt cache), as subrouter does; no immediate move.
- Mid-stream overload: move the session after 2 consecutive capacity failures, not at once.
- A healthy pinned session never moves; a move needs +10 points headroom only after its account is below 5 %.
- Codex capacity failover: on for conversations below about 32k tokens, off above.
- Drain on takeover is longer than the 8-minute overload wait, and the old router sends Connection: close at once.
Money decisions for Lawrence, OFF until he answers: spending paid Claude extra usage after the pool is exhausted; auto-redeeming Codex reset credits.
## F. Phases (each phase writes red tests first)
1. Crate, `acpmux router serve`, listeners, security gate, keys. Red tests: Origin, Host rebinding, foreign key, `LoopbackAddr`, OPTIONS, body limit. Needs the main WINDOW (new member, Cargo.lock, acpmux Cargo.toml; add all dependencies now). Gates: Testbox, plus the Windows jobs (the crate uses `cfg(unix)`).
2. Keychain store behind a trait, `config.json`/`state.json`, redaction, panic hook. Red tests: no secret in Debug, logs or a panic. The Keychain test runs on a fleet Mac (headless). WINDOW-LITE.
3. Messages and Responses forwarding, SSE passthrough, auth swap, upstream header timeout. Gate: Testbox with a mock hyper upstream.
4. Routing policy. Red tests replay the sticky-loop, mid-stream-overload and debit-floor bugs. Gate: Testbox.
5. OAuth, refresh single-flight, usage polling, with fake token endpoints. Gate: Testbox.
6. acpmux integration: start the router, `routerBuild`, takeover and drain, route env per harness, pool fingerprint, sandbox port. Gates: Testbox, plus the sandbox canary on a fleet Mac. This phase needs a WINDOW only if it changes the protocol spec or the schema (`acpmux-schema.json`).
7. Swift UI. Gates: compile with `nx-remote --host cmux-mini-6 --xcode 26.6`; Swift and GUI tests on cmux-lawrence-2.
8. Webviews picker mark and status chip. Gate: the webviews checks (bun test, typecheck, biome).
9. Hosted upstream account and the hq-ff contract fixtures.

## Decisions for Lawrence
1. Legal and money: the router pools many consumer Claude and ChatGPT subscriptions with the CLIs' own OAuth client ids. Both providers' terms can restrict this.
2. Taste: there is no Settings > Agents section. Use Settings > Accounts (my default), or add a new Agents section.
3. Taste: does a priority drag mean strict fill-first, or a spread inside each tier (my default)?

### Critical Files for Implementation
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/Cargo.toml (workspace members; needs the WINDOW)
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/crates/acpmux/src/hub/spawn.rs (route env at spawn)
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/crates/acpmux/src/config.rs (replace the subrouter fallback near line 773)
- /Users/lawrence/fun/cmuxterm-hq/repo/cmux-tui/crates/cmux-local-auth/src/lib.rs (Host, Origin and token checks to reuse)
- /Users/lawrence/fun/cmuxterm-hq/repo/Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxVersionHandoff.swift (update handoff; add the router build)

## Lead decisions (hq-5c, 2026-10-07)
- UI home: Settings > Accounts ("Model accounts"), matching the Settings redesign P2 category Accounts.
- Priority: spread inside each priority tier (not strict fill-first).
- Pooling consumer subscriptions: legal question for Lawrence; phases 1-4 (security core, keys, forwarding, routing with API-key accounts) do not depend on it.

## Chief rule (2026-10-07)
OAuth account pooling (several consumer Claude or ChatGPT logins) stays behind a flag, OFF by default, until Lawrence answers the legal question. API-key accounts and one personal login per provider are not affected.

## Lawrence decision (2026-10-07, via chief), replaces the OFF-by-default flag
"yes by default, it will run on user's own computer, we need to get to subrouter parity in terms of logic and everything, but in rust https://github.com/manaflow-ai/subrouter"
- Pooling of the user's OWN Claude and ChatGPT subscriptions is ON by default, no flag gate. Local only; credentials in the user's Keychain; they never leave the machine. Never pool accounts of different users.
- Target: logic parity with subrouter (account selection and scoring, capacity and overload handling, sticky sessions, retries, refresh, cache economics), in Rust. A parity matrix (feature -> subrouter file -> Rust module -> test) goes into plans/cmux-next/local-coderouter.md before phase 2.

## Parity matrix adopted (2026-10-07)
parity-matrix.md (123 rows, subrouter origin/main 44cb715) is the behavior source. Where it differs from this plan, the matrix wins, except in the 10 rows that would copy a known bug: those use the corrected behavior in the matrix. Main changes to this plan:
- Codex does not read OPENAI_BASE_URL for its built-in provider: acpmux gives Codex a custom model_provider (supports_websockets=true) that points at the router.
- Claude 529 and 5xx: wait on the same account (keeps the prompt cache), as subrouter does; no immediate move.
- Mid-stream overload: move the session after 2 consecutive capacity failures, not at once.
- A healthy pinned session never moves; a move needs +10 points headroom only after its account is below 5 %.
- Codex capacity failover: on for conversations below about 32k tokens, off above.
- Drain on takeover is longer than the 8-minute overload wait, and the old router sends Connection: close at once.
Money decisions for Lawrence, OFF until he answers: spending paid Claude extra usage after the pool is exhausted; auto-redeeming Codex reset credits.
