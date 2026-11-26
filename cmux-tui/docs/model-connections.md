# Model connections in Settings

Status: contract for the `cloud-models-connections` integration branch (off `cloud-multiplayer`).
Every lane builds against this file; change it here first, in the same commit as the code.

## Revision 3 wire format for owner-supplied endpoints on Cloud

A Cloud start can carry an endpoint credential alongside the existing launch credentials.
The owner's Mac reads the key from its existing Keychain reference. The machine's
daemon relays the credential to acpmux over its own Unix socket.

```json
{
  "env": { "CMUX_BYO_API_KEY": "<key>" },
  "endpoint": {
    "kind": "openai",
    "baseUrl": "https://api.deepseek.com",
    "models": ["deepseek-chat"]
  }
}
```

- `openai` takes exactly `CMUX_BYO_API_KEY`. The machine launches `opencode` with the
  model ID `byo/<model>`. In OpenCode's inline configuration the key is an environment reference.
- `anthropic` takes exactly `ANTHROPIC_AUTH_TOKEN`. The machine launches `claude` with the
  provider's model ID and derives the Anthropic model and slot variables. This
  launch excludes user and project settings that can replace its provider and
  refuses a conflicting managed provider configuration.
- The machine validates the endpoint and constructs the environment after clearing inherited
  provider routes. Cloud URLs require HTTPS with a public host. Loopback, private IP literals
  and local names are refused. At spawn, acpmux also checks that the machine's DNS
  answers are public. URLs cannot contain user info, credentials or substitutions.
  The harness owns subsequent DNS resolution and redirects.
- Only the owner's Mac can supply a launch credential to their own Cloud machine. The key is
  held in memory on the machine and passed in the agent's environment. An adopted agent's
  environment supplies both the key and endpoint metadata after a daemon restart. Neither
  is included in diagnostics, argv, journals, events or mirrored state.
- The guest retains this wire format for compatibility. The Mac requires the guest to advertise
  `agent-session-start-endpoint-credentials-v1` before sending it. The current guest does
  not advertise that capability. A saved key also requires the guest's bound credentials
  and reattach capabilities so the Mac can withdraw or redeliver it for the same session.

A native key uses the existing `env` object with `GEMINI_API_KEY` for Gemini,
`GOOGLE_API_KEY` for Vertex AI, or `XAI_API_KEY` for xAI. Cloud launches with these keys
require the installed harness and the bound credentials capability. The native launch
clears alternate keys and routing variables for its provider before setting the saved key.

An owner machine reports the endpoint harnesses it has installed. Cloud Settings
uses that answer to offer compatible providers. The composer can select a
configured endpoint while it is still choosing a machine. It reports that
profile as pending until a named machine confirms its harness. The start
checks the live link again before sending the credential.

## Goal

A person's Cloud threads run on the model and account selected in the picker. The owner's Mac
delivers an eligible saved credential to the agent on the owner's machine. Claude can also use
the machine's own login or the team route. When the selected model needs a connection, the
person can open Settings > Cloud > Cloud models.

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
  { "id": "codex-login", "kind": "codex-login|claude-login|subscription|chatgpt-plan|claude-token|grok-plan|copilot-plan|api-key|endpoint",
    "provider": "openai|anthropic|openrouter|google|xai", "families": ["codex"],
    "label": "ChatGPT", "email": "a@b.c|null", "plan": "pro|null", "signed_in": true,
    "enabled": true, "default_for": ["codex"], "serves_cloud": false, "can_serve_cloud": false }
  ```
  `id` is the route id. `enabled` is the general routing switch. `can_serve_cloud` is eligibility,
  and `serves_cloud` also reflects the saved Cloud preference. The credential operation checks
  Cloud use again before resolving a key.
- `_acpmux/connections/key.add` accepts an optional `servesCloud` boolean when creating a key.
  `_acpmux/account/set` takes `{id, servesCloud}` to change an existing API-key route.
  The preference is stored as `cloud_enabled` in the existing route file. Editable endpoint
  profiles store the same field, set through the revision-checked harness edit.
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
- `_acpmux/connections/chatgpt.device.begin` `{ "id": "optional chatgpt-plan route to reconnect" }`
  -> `{ "attempt": "opaque", "user_code": "...", "verification_url": "...", "expires_at": unix, "interval": seconds }`.
  The Cloud state uses this flow. The person opens the link and enters the code.
  The daemon polls OpenAI and allows 15 minutes. Another window starting the same sign-in
  joins the running attempt.
- `_acpmux/connections/chatgpt.device.wait` and `_acpmux/connections/chatgpt.device.cancel` take
  `{ "attempt": "..." }`. Wait answers like `chatgpt.wait`. Cancel stops polling and returns the final
  status. All three device methods require person proof on the local Unix socket.
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
- `_acpmux/connections/remove` `{ "id", "instance" }`: a chatgpt-plan connection revokes its refresh token
  (revocation endpoint from the OpenID configuration), clears tokens, keeps `client_id` + host id.
  Other kinds delegate to the existing `_acpmux/route/remove`.
- `_acpmux/connections/key.add` accepts `provider`, a `keychain:ITEM` reference, and optional
  `label` and `servesCloud` fields. To replace a key in place, send the route's id as `replace`
  and its current instance as `replaceInstance`. A route with `can_replace_key: true` supports
  this operation. The app strips whitespace from the pasted key, stores it in the Keychain,
  and calls `key.check` with the reference before saving the route.
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
- Cloud device sign-in follows [the upstream implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/device_code_auth.rs).
  POST `client_id` as JSON to `https://auth.openai.com/api/accounts/deviceauth/usercode` for
  `device_auth_id`, `user_code` (also `usercode`), and an interval in seconds as a string.
  The verification page is `https://auth.openai.com/codex/device`. POST `device_auth_id` and
  `user_code` to `/api/accounts/deviceauth/token` at that interval. HTTP 403 and 404 indicate
  pending approval unless an explicit terminal error is present. Slow-down responses add
  five seconds per [RFC 8628](https://www.rfc-editor.org/rfc/rfc8628.html#section-3.5).
  Approval returns `authorization_code`, `code_challenge`, and `code_verifier`. Exchange the
  code with its verifier and redirect URI `https://auth.openai.com/deviceauth/callback`.
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
- On macOS, ChatGPT and Kimi Code subscription grants use the existing `cmux-vault`
  login Keychain service. The per-provider index contains a reference, identity and
  expiry metadata. A legacy ChatGPT file is replaced by metadata only after the vault
  accepts the grant. A locked or unavailable Keychain leaves the file intact.
- Non-Mac ChatGPT connections retain the existing private JSON format. Other supported
  subscriptions use the base vault's OS secret store or daemon memory. The owner's
  Cloud machine receives the launch credential through its authenticated owner link.
- The ChatGPT route uses kind `chatgpt-plan`, family `codex`, and the Codex backend.
  `_acpmux/connections/credential` delivers `CMUX_CHATGPT_ACCESS_TOKEN` to the owner link.
  The Cloud session records the connection ID and selected model, and the Mac resends the
  credential when the person reopens the chat.

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

## Connect from Models on this Mac

Models offers ChatGPT, Claude and Kimi Code. It shows the supported local sign-ins
already on this Mac. The Mac login uses the shared account sign-in card. The ChatGPT
connection for Cloud has a separate device approval because the Mac supplies that
grant to launches on the owner's Cloud machine. Claude on Cloud signs in on the
machine that runs the chat.

### SuperGrok and GitHub Copilot

Connect shows these subscriptions as unavailable. Their native launch adapters
require new credential cache files. The existing CLI sign-ins remain available
on their own machines.

### Key and endpoint connections

Anthropic and OpenAI API keys use Claude Code and Codex. Google and xAI keys use Gemini CLI
and Grok Build. The OpenRouter key can also launch OpenCode for non-Claude models. The
existing Claude route uses Anthropic Messages. The OpenCode route uses Chat Completions.

OpenAI-compatible endpoint presets use OpenCode. The model picker uses
the endpoint's saved model IDs. Morph starts with the two Morph Ultra models. OpenCode Go
uses its documented model-list URL and puts a stable session ID on inference requests.
Bedrock defaults to its Mantle endpoint and Azure accepts a v1 resource URL with deployment
model IDs. Newly added Meta connections use the Model API endpoint.

Cloud models accepts setup before a machine reports its harnesses. An exact image revision
can supply the installed runners for older daemons. The live owner-link credential checks
still apply when starting a chat.

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
    chatgptDevice:
      | { phase: "idle" | "starting" | "cancelling" }
      | { phase: "waiting"; userCode: string; verificationURL: string; expiresAt: number }
      | { phase: "connected"; id: string }
      | { phase: "failed"; error: string };
  };
  type ModelConnection = { id: string; kind: "codex-login" | "claude-login" | "subscription" | "chatgpt-plan" | "api-key";
    provider: "openai" | "anthropic" | "openrouter" | "google" | "xai"; families: string[]; label: string;
    email: string | null; plan: string | null; signedIn: boolean; enabled: boolean; defaultFor: string[] };
  ```
- `cmux.settings.models.run` with `ModelsRun`:
  `{action:"order", ids}`, `{action:"spread", on}`, `{action:"enable", id, on}`, `{action:"remove", id}`,
  `{action:"connectChatGPTDevice", id?}`, `{action:"openChatGPTDevice"}`, `{action:"cancelChatGPTDevice"}`,
  `{action:"connectClaude"}`
  (existing Claude account sign-in), `{action:"addKey", provider, key, label?}` (the app moves `key`
  into the Keychain; it never reaches acpmux or disk otherwise), `{action:"orgKey", agent, key|null}`
  (existing `team.agent_key.set|remove`), `{action:"members", ownConnections?, chooseRunout?}`.
- Stream `cmux.settings.models.changed` -> `ModelsState`.
- **Settings > Models** shows local sign-ins, keys and endpoints, in connection order.
  Existing Claude Code, Codex, Gemini CLI, Grok Build and Cursor sign-ins appear automatically. Connect offers
  direct subscriptions, provider API keys and endpoints. Spread usage, team keys and the members
  policy live here.
- **Settings > Cloud > Cloud models** shows Claude machine logins, Claude setup tokens, ChatGPT
  device sign-ins and eligible API keys. A key or endpoint added in Models starts with Cloud use off.
  Adding it from Cloud models enables it for Cloud. Use the row menu to change Cloud use for a
  key or an editable endpoint. Existing connections keep their Cloud eligibility until changed.
- Cloud setup links from the model picker and from a held send open
  `#/settings/cloud?focus=card.cloudModels&provider=<family-or-provider>&open=<visit-id>`.
  A held send adds `fromSend=1` and resumes when the requested family gets a usable connection.
  Claude opens browser approval. ChatGPT uses the device code flow. A held Codex send opens
  an OpenAI key when ChatGPT sign-in for Cloud is unavailable for that flow.
- `cmux://settings/models` and `cmux://settings/models/add` open Models and its Connect picker.
  `cmux://settings/cloud/models` opens Cloud models. `cmux://settings/cloud/models/add` opens
  its Connect picker. Older Cloud setup paths and provider or Cloud focus links under Models
  still resolve. The Settings action accepts `setting=card.cloudModels`, `cloud.claude`,
  `cloud.chatgpt`, or `cloud.apiKey`; the same action is available from the palette, CLI and MCP.

Members policy (backend `backend/apps/api`, lane D): `team.models_policy.get|set` beside
`team.agent_key.*`, owner/admin write, defaults above. Enforcement in the platform route is
out of this repo and noted as a follow-up.

Before a Cloud chat starts, the app checks the selected model's eligibility, the owner's
connections, and the team route for that machine. The Set up Cloud card can open Claude sign-in
on the target machine or send the person to Settings to connect the requested provider.

## Original gateway design for the picker's model and account (lane E)

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
- **Claude machine login**: Models uses Claude Code's sign-in on the Mac. Cloud models can
  run `claude auth login --claudeai` on the selected owner machine. The owner can also sign
  in from the first Cloud chat. The app opens the approval link on the Mac with localhost
  forwarded to Claude Code on that machine. The person can paste Claude's approval code when
  Claude supplies a manual link. Reauthenticate requests fresh approval for that machine.
  Sign Out runs `claude auth logout` there. A start that selects the machine login uses that
  account even when other Claude API credentials are configured.
- **Claude setup-token connections**: The daemon's one-click `claude_token.begin` flow saves
  the token by reference. Pasted setup tokens strip whitespace so wrapped values still work.
  `cmux cloud connect claude` captures the token from `claude setup-token`, or reads it with
  `--token-stdin`, and registers a `claude-token` connection. The add request takes a
  `keychain:`, `env:` or absolute `file:` reference as `secret` and an optional `label`.
  An Anthropic API key also serves Claude. Models shows legacy setup-token rows with
  “Sign in again with Claude”. A successful migration removes the migrated route and its
  Keychain item. Cancelled and expired attempts leave the route in place.
- **Claude chat recovery**: When a saved token is refused, recovery signs in on that chat's
  exact owner machine and switches only that chat to the machine login. Other chats keep
  their saved credentials. Recovery uses distinct start and finish methods, so an older
  guest refuses it before changing the machine's login preference.
- **Codex**: `chatgpt-plan` (Sign in with ChatGPT, lane A as built) or an OpenAI API key.
- The existing Mac CLI logins (`codex-login`, `claude-login`) stay listed for local chats but do not
  serve Cloud (`serves_cloud: false`) in this revision.

Delivery (`_acpmux/connections/credential {id}` -> `{ "family", "kind", "env": {NAME: value},
"expires_at": unix|null }`, local unix socket only, never logged):
- Claude setup token -> `ANTHROPIC_AUTH_TOKEN` (for the owner's Cloud machine).
- Anthropic key -> `ANTHROPIC_API_KEY`;
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
- An owner Cloud machine can open Claude's sign-in card without a model
  connection. Other Cloud setup paths can open Settings to add a connection
  for the requested family.
- Before any send (CMUX-662): a new chat with Cloud picked reads `cloud.setup.state`
  (`{families: {claude?, codex?}}`, the same `CloudSetup` read a start makes), and the model picker
  shows a Connect row on each family nothing serves. Connect runs that family's way in.
- Organization: team shared keys (`team.agent_key.*`, served by the platform edge) stay listed;
  the team gateway row is removed from the page.
