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
- `_acpmux/connections/chatgpt.token` `{ "id": "..." }` -> `{ "access_token": "...", "expires_at": unix }`.
  Local socket only, for the gateway. Refreshes when under 5 minutes left; refreshes for one id are
  serialized (one in flight; others await it). Never logged.
- `_acpmux/connections/remove` `{ "id" }`: a chatgpt-plan connection revokes its refresh token
  (revocation endpoint from the OpenID configuration), clears tokens, keeps `client_id` + host id.
  Other kinds delegate to the existing `_acpmux/route/remove`.
- `_acpmux/connections/key.add` `{ "provider", "secret": "keychain:ITEM", "label"? }` -> state.
  The app stores the pasted key in the Keychain first (as `cmux.chief.backend.add` does) and passes
  only the reference.
- Notification `_acpmux/connections.changed` with `ConnectionsState`, to watching (`_acpmux/watch`)
  unix-socket and local-app connections, after every change above and after a route or account write.

Lane A details (as implemented):
- `_acpmux/connections` may also be read by the local app; every other method is unix socket only.
- `remove` answers `ConnectionsState`; the CLI logins (`codex-login`, `claude-login`) are refused
  (turn them off instead). `chatgpt.cancel` answers `{ "attempt", "status" }`.
- `key.add` makes a `direct-api-key` route `<provider>-key[-N]` with a `provider` field:
  anthropic `[claude]` api.anthropic.com; openai `[codex]` api.openai.com/v1; openrouter
  `[claude, codex]` openrouter.ai/api(/v1), bearer; google `[gemini]`
  generativelanguage.googleapis.com/v1beta/openai; xai `[codex]` api.x.ai/v1. An inline key is
  refused (`route.secret_inline`).
- Errors carry `data.reason`: `connections.unknown_id`, `connections.duplicate_id`, `route.*`, or
  `chatgpt.<code>` with `data.code` (`not_found`, `signed_out`, `reauth_required`, `refresh_failed`,
  ...). `chatgpt.wait`'s `error` codes: `state_mismatch`, `access_denied`, `authorize_failed`,
  `no_code`, `no_client_id`, `token_exchange_failed`, `invalid_id_token`, `no_plan_scope`, `timeout`.
- A `chatgpt-plan` route never runs a chat on this Mac (`route.unavailable` at spawn; refused as a
  `route/default.set` default). A refresh answered `invalid_grant` clears the tokens (`signed_in`
  false, `reauth_required`) and keeps the identity for a reauth.

### Sign in with ChatGPT (OpenAI docs: developers.openai.com/siwc/token-sharing-open-source)

Implemented from the documented protocol; no DevKit code is copied (its license is noncommercial).
- Host id: `urn:uuid:<v4>` in `<acpmux home>/chatgpt/host.json` (0600), created before the first
  sign-in, one per installation, never user-identifying.
- Authorize `https://auth.openai.com/api/accounts/authorize`: `client_id=dynamic_agent_client`
  (first registration; afterwards the issued `oaiapp_...`), `agent_name_hint=cmux` (first only),
  `ext_agent_host_id`, `response_type=code`, `redirect_uri=http://127.0.0.1:<port>/auth/callback`,
  `scope=openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`,
  `resource=https://api.openai.com/v1`, fresh `state`, `nonce`, PKCE S256. Reauth adds
  `id_token_hint` (+ `login_hint`), omits `agent_name_hint`.
- Callback: check `state`; `error=access_denied` stops; a new registration must carry `client_id`
  (persist it before the exchange; never store `dynamic_agent_client`).
- Token `https://auth.openai.com/api/accounts/oauth/token` (form): code exchange with `client_id`,
  `code`, `code_verifier`, same `redirect_uri`, `resource`. Refresh: `grant_type=refresh_token`,
  `client_id`, `refresh_token`, `resource`, no `scope`. Access 1 h, refresh 30 d rotating: replace
  access, expiry, scopes and refresh token together, atomically.
- Validate the ID token (JWKS from the OpenID configuration; iss `https://auth.openai.com`,
  aud = issued client_id, exp, nonce). Require `chatgpt.tokens.use.direct` in granted scopes, else
  `no_plan_scope`. Identity is `sub`.
- Store one record per (client_id, sub): `<acpmux home>/chatgpt/<route id>.json`, 0600, atomic
  write. Route file kind `chatgpt-plan`, family `codex`, `openai_base_url=https://api.openai.com/v1`.
- UI must say "Using ChatGPT plan" with a Manage usage link to https://chatgpt.com/settings/usage,
  and the sign-in button reads "Continue with ChatGPT".

## Gateway (`cmux-tui/crates/cmux-tui/src/cli/inference_gateway*.rs`), lane B

- The personal gateway serves from `_acpmux/connections` in order (respecting `enabled`, `spread`)
  instead of only `--mac-logins`; `--mac-logins` stays as the fallback when the daemon is absent.
- A request carries the model the machine asked for; the gateway picks the first enabled
  connection whose families serve that model, and on an out-of-quota answer (429 with a usage
  limit) moves to the next one when `spread` is on.
- `chatgpt-plan`: `Authorization: Bearer <chatgpt.token>` to `https://api.openai.com/v1/responses`.
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
  (the person runs it; cmux never implements Claude's OAuth). Settings > Models > Claude Code opens
  a cmux terminal tab running `claude setup-token` and a paste field; the pasted value is checked
  (`sk-ant-oat` prefix, no whitespace), stored in the Keychain, and only `keychain:ITEM` reaches
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
  OpenAI-documented provider (`model_provider="openai_chatgpt_plan"`, base_url
  `https://api.openai.com/v1`, `env_key="CMUX_CHATGPT_ACCESS_TOKEN"`, `wire_api="responses"`,
  `requires_openai_auth=false`, `supports_websockets=false`, no `tool_search`).
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

Lane A, Revision 2 as implemented: `claude_token.add` makes route `claude-token[-N]` (route kind
`claude-token`, secret reference only; an inline value is `route.secret_inline`). `serves_cloud` is
true for `chatgpt-plan`, `claude-token` and `api-key` with provider anthropic or openai, else false.
`credential` errors carry `data.reason` `connections.not_cloud`, `connections.secret_unresolved`,
`connections.no_secret` or `chatgpt.<code>`; a `claude-token` or `chatgpt-plan` route never runs a
chat on this Mac and cannot be a `route/default.set` default.
