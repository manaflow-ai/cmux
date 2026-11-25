# Model connections (Settings > Models, Cloud threads)

Status: contract for the `cloud-models-connections` integration branch (off `cloud-multiplayer`).
Every lane builds against this file; change it here first, in the same commit as the code.

## Goal

A person's Cloud threads run on the same model and the same subscription or key the model picker
shows on the Mac, with nothing to set up. Cloud machines hold no provider token: a machine calls
the coderouter edge with a placeholder key; the edge's team Durable Object hands the request to a
gateway (this Mac's personal gateway, or the team's gateway machine) that holds the logins,
refreshes them, and forwards upstream. When nothing can serve the chosen model, the person is
asked once to set up Cloud in Settings > Models (Capy's "Models" page is the reference: ordered
connections, an Add a connection sheet with Subscriptions and API keys).

## Concepts

- **Connection**: one way to pay for a model. Kinds:
  - `codex-login`, `claude-login`: the CLI's own login on this Mac (existing acpmux built-in routes).
  - added accounts (existing acpmux `direct-subscription` routes with their own `account_home`).
  - `chatgpt-plan`: Sign in with ChatGPT (OpenAI, open-source track), new. See below.
  - `api-key`: a provider key (`anthropic`, `openai`, `openrouter`, `google`, `xai`) held as a
    secret reference (`keychain:ITEM`), never the value. Extends `direct-api-key` routes.
- **Your connections**: this person's, in priority order. Default order with no explicit order set:
  the picker's default account per family first, then the other signed-in accounts, then keys.
  Existing Mac logins appear here with no action (zero setup).
- **Spread usage across my subscriptions** (`spread`, default on): a thread may move to another
  connection that serves the same model when one is out, staying on one while its cache is warm.
- **Organization connections**: the team's, used after a member's own: the team gateway
  (`mode`/`machine`, existing platform route) and team shared keys (existing `team.agent_key.*`).
- **Members policy** (team setting, owners/admins edit): `membersOwnConnections` (default true),
  `membersChooseRunout` (default false).

## acpmux RPC (Rust daemon, `cmux-tui/crates/acpmux`)

All on the existing unix socket; method names in `rpc.rs`. Lane A owns these.

- `_acpmux/connections` -> `ConnectionsState`
  ```json
  { "connections": [Connection], "spread": true, "order_explicit": false }
  ```
  `Connection`:
  ```json
  { "id": "codex-login", "kind": "codex-login|claude-login|subscription|chatgpt-plan|api-key",
    "provider": "openai|anthropic|openrouter|google|xai", "families": ["codex"],
    "label": "ChatGPT", "email": "a@b.c|null", "plan": "pro|null", "signed_in": true,
    "enabled": true, "default_for": ["codex"], "serves_cloud": true }
  ```
  `id` is the route id. `enabled` is the existing routing switch. `serves_cloud` is false only when
  the connection cannot be served through the gateway (none today; reserved).
- `_acpmux/connections/order.set` `{ "ids": ["..."] }` -> state. Unknown ids are an error; missing
  ids keep their default order after the listed ones. Stored in `<acpmux home>/routes/bindings.json`
  as `connection_order`, `spread`.
- `_acpmux/connections/spread.set` `{ "on": bool }` -> state.
- `_acpmux/connections/chatgpt.begin` `{ "id": "optional existing chatgpt-plan id (reauth)" }`
  -> `{ "attempt": "opaque", "url": "https://auth.openai.com/api/accounts/authorize?..." }`.
  The daemon starts a `127.0.0.1:<ephemeral>/auth/callback` listener before answering. The app opens
  `url` in the person's browser (NSWorkspace), never the daemon.
- `_acpmux/connections/chatgpt.wait` `{ "attempt": "..." }` -> `{ "status": "pending|done|failed|cancelled",
  "connection": Connection|null, "error": "access_denied|no_plan_scope|...|null" }` (long-poll up to
  25 s; the app re-calls while pending). Completion also fires `_acpmux/connections.changed`.
- `_acpmux/connections/chatgpt.cancel` `{ "attempt": "..." }`.
- `_acpmux/connections/claude_token.begin` `{ "label": "optional" }` -> `{ "attempt": "opaque",
  "url": "https://claude.ai/oauth/authorize?...|null" }`. One-click Claude: the daemon runs
  `claude setup-token` itself (`crates/acpmux/src/claude_token/`), as its own child in a hidden pty
  240 columns wide: `CMUX_CLAUDE_BIN`, else `claude` on the login PATH or in `~/.local/bin`; no
  `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` in its environment; `BROWSER=/usr/bin/true`, so
  it opens no browser of its own. It answers once the child prints its sign-in link (read from the
  OSC 8 hyperlink or the plain text, escapes stripped); the app opens `url` in its own browser on
  this Mac, and the sign-in returns to the child's loopback listener. One attempt at a time: a new
  begin cancels the pending one. Errors (`data.reason`): `claude_token.no_claude` (nothing to run),
  `claude_token.no_url` (no link in 30 s, or the child ended first; the child is ended and the
  message carries its last line), `claude_token.spawn`, `claude_token.pty`.
- `_acpmux/connections/claude_token.wait` `{ "attempt": "..." }` -> `{ "status":
  "pending|done|failed|cancelled", "connection": Connection|null, "error":
  "no_token|cut_short|store|add|timeout|null" }` (long-poll up to 25 s). The token is taken out of
  the child's output (`pty::TokenFilter`, the copy `cmux cloud connect claude` uses too), stored in
  the login Keychain as `cmux-model-key` / `claude-token-<8 hex>`, and added with
  `claude_token.add`'s path holding only `keychain:cmux-model-key/ACCOUNT`; a refused add deletes
  the item. The child's process group is ended after the token. The token is in no reply, log line
  or error, and its buffers are zeroized. Completion also fires `_acpmux/connections.changed`.
- `_acpmux/connections/claude_token.code` `{ "attempt": "...", "code": "..." }` -> `{ "attempt",
  "status": "pending" }`: when the sign-in page shows a code to paste back, the app hands it here;
  every whitespace character is taken out and the code and Return are typed into the child.
  `claude_token.bad_code`, `claude_token.not_pending`.
- `_acpmux/connections/claude_token.cancel` `{ "attempt": "..." }` -> `{ "attempt", "status" }`:
  ends the child.
- `_acpmux/connections/chatgpt.token` `{ "id": "..." }` -> `{ "access_token": "...", "expires_at": unix }`.
  Local socket only, for the gateway. Refreshes when under 5 minutes left; refreshes for one id are
  serialized (one in flight; others await it). Never logged.
- `_acpmux/connections/chatgpt.import` `{ "secret_file": "/abs/path/auth.json" }` -> `{ "connection": Connection }`.
  CI only (cmuxterm-hq#15720): refused unless the daemon's environment sets `ACPMUX_CI_CHATGPT_IMPORT=1`,
  and on every connection but the local unix socket. Reads a Codex CLI `auth.json`, requires its ID
  token to be issued to Codex's client, and writes the same record and `chatgpt-plan` route a browser
  sign-in does. Import into a fresh acpmux home per job: the first refresh rotates the refresh token.
- `_acpmux/connections/remove` `{ "id" }`: a chatgpt-plan connection revokes its refresh token
  (revocation endpoint from the OpenID configuration), clears tokens, keeps `client_id` + host id.
  Other kinds delegate to the existing `_acpmux/route/remove`.
- `_acpmux/connections/key.add` `{ "provider", "secret": "keychain:ITEM", "label"? }` -> state.
  The app stores the pasted key in the Keychain first (as `cmux.chief.backend.add` does) and passes
  only the reference. The app first takes every whitespace character out of the paste (a wrapped key
  is still one key), then calls `key.check`.
- `_acpmux/connections/key.check` `{ "provider", "secret": "keychain:ITEM" }` -> `{ "provider",
  "result": "ok|bad_shape|bad_key|unreachable", "save", "http_status", "detail", "message" }`
  (`key_check.rs`). The vendor prefix first (openai `sk-`, anthropic `sk-ant-`, openrouter `sk-or-`,
  google `AIza`, xai `xai-`), then one authenticated read (the model list; OpenRouter's
  `/api/v1/key`), 8 s. 401/403 (and Google's or xAI's 400) is `bad_key`, `save: false`, `message`
  "Key rejected by OpenAI"; a network failure, timeout or 5xx is `unreachable` and saves anyway.
  The key is resolved in the daemon and never answered or logged.
- Notification `_acpmux/connections.changed` with `ConnectionsState`.

### Sign in with ChatGPT (Codex's own sign-in, cmux#45774)

The same ChatGPT sign-in `codex login` runs, so the token is the one Codex runs on: a Cloud chat's
Codex sends its turns to the ChatGPT Codex backend `https://chatgpt.com/backend-api/codex` with the
token's `chatgpt_account_id` as `chatgpt-account-id`, exactly as the person's own Codex does.
(The first version used OpenAI's token-sharing protocol, developers.openai.com/siwc: a
`chatgpt.tokens.use.direct` token for api.openai.com. OpenAI answered
`subscription_sharing_user_not_eligible` for every model on a Pro account, so it is gone; a record
of its `oaiapp_...` client reads signed out and the person signs in again.)
- Authorize `https://auth.openai.com/oauth/authorize`: `client_id=app_EMoamEEZ73f0CkXaXp7hrann`
  (Codex's), `response_type=code`, `redirect_uri=http://localhost:1455/auth/callback` (the port
  Codex's client is registered with; a newer sign-in ends a pending one, a port another program
  holds fails `port_busy`), `scope=openid profile email offline_access api.connectors.read
  api.connectors.invoke`, `id_token_add_organizations=true`, `codex_cli_simplified_flow=true`,
  `originator=codex_cli_rs`, fresh `state`, `nonce`, PKCE S256. Reauth adds `login_hint`.
- Callback: check `state`; `error=access_denied` stops.
- Token `https://auth.openai.com/oauth/token`: the code exchange as a form (`client_id`, `code`,
  `code_verifier`, same `redirect_uri`); a refresh as Codex's JSON body (`client_id`,
  `grant_type=refresh_token`, `refresh_token`, `scope=openid profile email`). Refresh tokens
  rotate: replace access, expiry, scopes and refresh token together, atomically. `invalid_grant`,
  `refresh_token_expired`, `_reused` or `_invalidated` signs the account out until a reauth.
- Validate the ID token (JWKS from the OpenID configuration; iss `https://auth.openai.com`,
  aud = Codex's client id, exp; a nonce, when echoed, must be the one sent). It must name a
  `chatgpt_account_id`, else `no_chatgpt_account`. Identity is `sub`.
- The daemon owns this login, never the Mac's `~/.codex`: refreshing it never signs the person out
  of Codex on the Mac.
- Store one record per (client_id, sub): `<acpmux home>/chatgpt/<route id>.json`, 0600, atomic
  write. Route file kind `chatgpt-plan`, family `codex`, `openai_base_url` the Codex backend.
- `_acpmux/connections/credential` answers it as `CMUX_CHATGPT_ACCESS_TOKEN` (ten minutes left at
  least); the machine runs Codex on the `openai_chatgpt_plan` provider to the ChatGPT Codex backend (agent_credentials.rs).
- UI must say "Using ChatGPT plan" with a Manage usage link to https://chatgpt.com/settings/usage,
  and the sign-in button reads "Continue with ChatGPT".

## Gateway (`cmux-tui/crates/cmux-tui/src/cli/inference_gateway*.rs`), lane B

- The personal gateway serves from `_acpmux/connections` in order (respecting `enabled`, `spread`)
  instead of only `--mac-logins`; `--mac-logins` stays as the fallback when the daemon is absent.
- A request carries the model the machine asked for; the gateway picks the first enabled
  connection whose families serve that model, and on an out-of-quota answer (429 with a usage
  limit) moves to the next one when `spread` is on.
- `chatgpt-plan`: `Authorization: Bearer <chatgpt.token>` to `https://chatgpt.com/backend-api/codex/responses` with `chatgpt-account-id`.
  Plan route limits (preview): force `store:false`, `stream:true`; drop `previous_response_id`,
  `background`, `conversation`, `max_output_tokens`, `max_tool_calls`, `metadata`, `moderation`,
  `prompt`, `prompt_cache_retention`, `safety_identifier`, `temperature`, `top_logprobs`, `top_p`,
  `truncation`, `user`; reject `tool_search`; system-role input items become developer.
- `api-key`: provider base URL + the resolved secret (anthropic `x-api-key`, others Bearer).
- The machine side never changes per connection: Codex on a Cloud machine talks Responses to the
  edge with a placeholder key (`requires_openai_auth=false`, `supports_websockets=false`).

## App (Swift) and Settings webview, lanes C and D

Settings ops (`webviews/src/pages/settings/ops.ts`; Swift `SettingsPageProvider.swift`):
- `cmux.settings.models.state` -> `ModelsState`
  ```ts
  type ModelsState = {
    personal: { connections: ModelConnection[]; spread: boolean; available: boolean };
    organization: {
      team: { id: string; name: string } | null;
      canEdit: boolean;
      gateway: { mode: "gateway" | "off"; machine: string | null; online: boolean } | null;
      keys: { agent: "claude" | "codex"; set: boolean; last4: string | null }[];
    };
    members: { ownConnections: boolean; chooseRunout: boolean; canEdit: boolean } | null;
    chatgpt: { attempt: string | null; error: string | null };
  };
  type ModelConnection = { id: string; kind: "codex-login" | "claude-login" | "subscription" | "chatgpt-plan" | "api-key";
    provider: "openai" | "anthropic" | "openrouter" | "google" | "xai"; families: string[]; label: string;
    email: string | null; plan: string | null; signedIn: boolean; enabled: boolean; defaultFor: string[] };
  ```
- `cmux.settings.models.run` with `ModelsRun`:
  `{action:"order", ids}`, `{action:"spread", on}`, `{action:"enable", id, on}`, `{action:"remove", id}`,
  `{action:"connectChatGPT", id?}`, `{action:"cancelChatGPT"}`, `{action:"connectClaude"}`
  (existing Claude account sign-in), `{action:"addKey", provider, key, label?}` (the app moves `key`
  into the Keychain; it never reaches acpmux or disk otherwise), `{action:"orgKey", agent, key|null}`
  (existing `team.agent_key.set|remove`), `{action:"members", ownConnections?, chooseRunout?}`.
- Stream `cmux.settings.models.changed` -> `ModelsState`.
- Settings layout: new sidebar category `models` ("Models"), card `models`, in
  `schemas/settings/source/page-layout.json`, placed right after Agents. Route
  `cmux://settings/models` opens it; `cmux://settings/models/add` opens the Add a connection sheet.
- Settings > Cloud (category `cloud`, after Models; 2026-11-12): card `cloudModels` ("Models for
  Cloud") lists Claude, ChatGPT and API key, each "Connected for Cloud" when an enabled, signed-in
  `serves_cloud` connection of that family exists (or the team's shared key), else "Not set up for
  Cloud" with Set Up (the same Add a connection steps) and a plain note when only a This Mac only
  login exists. The Cloud Environments card and the Cloud Workspaces rows live there too. Routes:
  `cmux://settings/cloud`, `/cloud/claude`, `/cloud/chatgpt`, `/cloud/api-key`
  (`#/settings/cloud?focus=cloud.<row>`); the chat's Set up Cloud card opens the row its button names.

Members policy (backend `backend/apps/api`, lane D): `team.models_policy.get|set` beside
`team.agent_key.*`, owner/admin write, defaults above. Enforcement in the platform route is
out of this repo and noted as a follow-up.

Cloud first use (lane D): before a Cloud chat starts, the app asks the personal gateway whether a
connection serves the picker's model (`_acpmux/connections`, family of the chosen agent, plus the
organization's gateway/keys). If one does, the chat starts on the picker's model and account with
no prompt. If none does, the chat shows a "Set up Cloud" card ("Cloud threads use your
subscriptions. Connect one to start.") with buttons Continue with ChatGPT / Sign in to Claude /
Add an API key / Open Settings, and records nothing until a connection exists. The in-chat sign-in
card's ways in add the connection on this Mac instead of logging in on the machine.

## The picker's model and account in Cloud (lane E)

A Cloud chat starts on exactly what the model picker shows for that chat: the agent (Claude or
Codex), the model id, the effort, and the account the picker's Account menu selected (a route id,
or the family default). The app passes these in the Cloud start request; the machine's agent is
launched with that model and effort, and its requests carry the route id to the edge as the
`x-cmux-connection` header (placeholder key unchanged). The gateway serves the request with that
connection first, then the rest of the order when `spread` is on, then the organization's. A
connection that does not serve the model is skipped, never silently swapped for another model.
If nothing serves it, the chat shows the Set up Cloud card above, naming the model.

## Revision 2 (2026-11-12, Austin): no gateway; connections go straight to the machine

Product decision: Cloud chats work through connections alone, with no inference gateway machine
and no Mac gateway in the path. This supersedes the "Gateway" section and the
`x-cmux-connection` header seam above (lane B's gateway work is not part of the integration).

Connections (all held on the Mac: acpmux routes + Keychain references):
- **Claude**: `claude-token`, the long-lived token from Claude Code's own `claude setup-token`
  (cmux never implements Claude's OAuth). One click: the daemon runs `claude setup-token` itself
  (`claude_token.begin` / `wait` / `code` / `cancel` above) and stores the token; no terminal, no
  copy and paste. The paste field stays as a fallback: the pasted value is checked (`sk-ant-oat`
  prefix, every whitespace character taken out first, inner ones too: a terminal wraps and pads the
  printed line), stored in the Keychain, and only `keychain:ITEM` reaches
  acpmux (`_acpmux/connections/claude_token.add {secret, label?}` -> state; kind `claude-token`,
  provider anthropic, family claude). An Anthropic API key (`api-key`, anthropic) also serves Claude.
- **Codex**: `chatgpt-plan` (Sign in with ChatGPT, lane A as built) or an OpenAI API key.
- The existing Mac CLI logins (`codex-login`, `claude-login`) stay listed for local chats but do not
  serve Cloud (`serves_cloud: false`) in this revision.

Delivery (`_acpmux/connections/credential {id}` -> `{ "family", "kind", "env": {NAME: value},
"expires_at": unix|null }`, local unix socket only, never logged):
- claude-token -> `CLAUDE_CODE_OAUTH_TOKEN`; anthropic key -> `ANTHROPIC_API_KEY`;
  openai key -> `OPENAI_API_KEY`; chatgpt-plan -> `CMUX_CHATGPT_ACCESS_TOKEN` (fresh, >= 10 min left).
- At Cloud chat start the app picks the connection (picker's account if it serves Cloud, else the
  first enabled Cloud-serving connection of that family in order), reads its credential, and sends
  it over the machine session to the machine's acpmux with the agent launch. The machine's acpmux
  keeps it in memory for that agent only (never on disk, never in the machine's model-plane env)
  and launches the agent direct to the provider: it unsets the coderouter `ANTHROPIC_BASE_URL` /
  `OPENAI_BASE_URL` and placeholder keys for that agent. Codex with chatgpt-plan runs with the
  ChatGPT Codex backend, as Codex runs a ChatGPT sign-in (`model_provider="openai_chatgpt_plan"`,
  base_url `https://chatgpt.com/backend-api/codex`, `env_key="CMUX_CHATGPT_ACCESS_TOKEN"`, the
  token's `chatgpt_account_id` as `chatgpt-account-id` from `CMUX_CHATGPT_ACCOUNT_ID`,
  `wire_api="responses"`, `requires_openai_auth=false`, `supports_websockets=false`, no
  `tool_search`). The `-c` overrides go after `app-server`: codex 0.160 drops overrides before a
  subcommand that has its own (cmux#45774).
- ChatGPT refresh: the Mac holds the refresh token. While the app runs it pushes a new access token
  to each machine with a live chatgpt-plan agent about 10 minutes before expiry
  (`agent/credentials.update` on the machine's acpmux); the machine's acpmux restarts that Codex
  app-server with the new token and resumes the thread (`thread/resume`), as OpenAI documents. If
  the Mac is away past expiry, the chat says it needs this Mac to reconnect ChatGPT.
- With no Cloud-serving connection for the family, the chat shows the Set up Cloud card
  (Continue with ChatGPT / Set up Claude / Add an API key / Open Settings) and starts by itself
  once one is added. Without a credential the machine falls back to today's coderouter path.
- Organization: team shared keys (`team.agent_key.*`, served by the platform edge) stay listed;
  the team gateway row is removed from the page.
