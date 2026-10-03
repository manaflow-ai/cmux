# Integrations (`cmux/integrations`)

Connect GitHub, Linear, Slack or any OpenAPI, GraphQL or remote MCP API (Google Calendar and Gmail show as "coming"); see each connection's health; share it with your team; sign in again; disconnect; and choose per tool whether agents and automations may run it (Allow), must ask you first (Ask) or never run it (Block).

The app is a UI over the backend's one integration model (spec `integrations.md`, protocol `integrations.ts`): `Connection` records owned by `ConnectionDO`, credentials held only by the gateway, the team's `TeamIntegrationPolicy`, sharing `private | team`. The app keeps no second store: it renders what `integration.list` and `integration.policy.get` return and re-reads on change events. It never sees a token; a credential is an opaque `cred_…` handle that only the gateway resolves.

## Credits

The generic import (OpenAPI, GraphQL and MCP ingestion, tool paths, auth-method detection) and the policy pattern matcher and defaults live in the MIT package `@cmux/integrations-core` (`libs/integrations-core/`), adapted from [executor](https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan. The package's `NOTICE` lists the adapted files with their upstream paths, and each adapted file starts with the same credit. `pack.ts` bundles the package into `dist/main.js`, so this app ships `LICENSE-executor` as its notice. The app shows the credit under the importer and on generic connections. No telemetry, billing or registry-fetch code was copied.

## Contributions

| Id | Kind | What |
| --- | --- | --- |
| `integrations` | sidebar section | connections that need action, then "N connected" |
| `pane` | pane kind | the main surface (three variants), connection detail, connect gallery, API importer |
| `openIntegrations` | command (palette, section) | opens the pane, optionally on one connection |
| `connect` | command (palette) | starts connecting `github`, `linear` or `slack` |
| `importApi` | command (palette) | previews a spec URL or JSON in the importer |
| `cycleVariant` | command (palette, DEV/NIGHTLY) | next design variant |

No MCP tools: connecting needs a human at the provider, and agents already reach `integration.list` and provider ops through the backend catalog.

## Scopes

| Scope | Why |
| --- | --- |
| `integration:read` | list connections, their tools and the team policy |
| `integration:write` (optional) | connect, sign in again, share, disconnect (the shell confirms first), MCP exposure on or off, change a tool's policy, each on a click |
| `workspace:write` (optional) | open the pane from the palette or sidebar |

## Variants (DEV/NIGHTLY setting `variant`, palette "Next Integrations Variant")

| Variant | Design |
| --- | --- |
| `connections` (default) | list of connections, attention first; a row opens detail: health with Sign In Again, account, sharing, permissions, team policy line, Share / Disconnect, then the connection's tools with Allow / Ask / Block |
| `gallery` | onboarding first: every provider with Connect (or why not: not set up, blocked by team), "Any API" cards for OpenAPI, GraphQL and MCP, then your connections |
| `catalog` | every tool of every active connection with its policy, a filter field, and where each action comes from (default, your rule, team rule) |

Recommendation: `connections`. It matches how people think about integrations (an account they linked), and it puts health and re-auth first. Strongest objection: per-tool policy sits one level down, so an admin who asks "what may agents do?" must open each connection; `catalog` answers that question directly. A likely final shape is `connections` with a Tools tab that is the `catalog` view.

## Policy defaults (from the spec, before any rule)

Reads Allow, changes Ask, destructive Block (decided). Only a rule for the exact tool can loosen a destructive (Block) default; a broader rule (`ns.*`, `ns.*.delete`, `*`) that would allow or ask leaves it blocked, so a subtree rule never unblocks a delete by accident. The backend lead must confirm this rule: the gateway resolves policy with the same `resolveEffectivePolicy`. Defaults: OpenAPI GET/HEAD/OPTIONS, GraphQL queries and MCP `readOnlyHint` tools Allow; OpenAPI POST/PUT/PATCH, GraphQL mutations and un-annotated MCP tools Ask; OpenAPI DELETE, GraphQL mutations named with a destructive verb and MCP `destructiveHint` tools Block. First-class provider ops use the same mapping on the backend op's risk (read and mutate-own Allow, send-external and mutate-shared Ask, destructive and money Block). The full table, the rule patterns and the grant mapping are in `libs/integrations-core/README.md`; `defaultActionFor` there is the single source.

## Contract (final)

The backend lead's final answers. The app is built against mocks of them (`preview/make-fixtures.ts`); the gateway is built later.

1. **One record.** Generic connections (`provider: openapi | graphql | mcp`) use the `Connection` record with `catalog {kind, title, version, digest, source_url}` and `auth {kind}`, and count toward the team's 50 connections. The app shows "N of 50 connections" and disables Connect and Add at the limit; the owner refuses with `integration.limit`, which the app shows as the same message. Catalogs are content-addressed in ConnectionDO `catalog_blobs` (2 MB cap, `catalog.too_large`) and re-ingested daily; a change posts a feed notice, and the app shows "The API changed" from the record with an Open in Feed link. The app never polls.
2. **Rules.** Team rules live in ConnectionDO, user rules in UserDO; the most restrictive wins. Allow, Ask and Block map to grant approval `none`, `per_call` and no grant. Destructive tools default to Block (see "Policy defaults" for the exact-rule condition). The team policy's `generic_hosts` limits the hosts generic connections may target: the add flow shows the list and refuses other hosts before any call (`egress.host_not_allowed`); the owner enforces it for real.
3. **Egress.** Calls go through the external-effect ledger with SSRF-safe egress: no private, loopback, link-local or ULA targets, checked again after each redirect, 10 MB, 30 s. The URL import runs the same checks on the URL text first (`egress.private_target`, `egress.credentials_in_url`, `egress.invalid_url`) and shows the gateway's own refusals (`egress.private_target` after DNS, `egress.too_large`, `egress.timeout`) with the same texts.
4. **MCP.** Remote servers over Streamable HTTP, one session per connection in ConnectionDO. stdio is not supported: the importer refuses command lines and `{command}` / `mcpServers` configs (`import.mcp_stdio`), and the UI has no stdio option. One endpoint per principal, `/v1/mcp`. Tool names are `<namespace>__<path>` (dots become `-`), at most 64 characters, with a hash suffix when cut or lossy: `mcpToolName` and `assignMcpToolNames` in `@cmux/integrations-core`. Ask tools wait for approval in the feed or through MCP elicitation; Block tools are hidden. MCP exposure is opt-in per connection (Off and On in the detail screen; off by default).
5. **Code.** `libs/integrations-core` (MIT, with `NOTICE`) is the only home of ingestion, policy resolution, egress pre-checks and MCP naming.
6. **Credentials.** API key, bearer, basic, custom headers, OAuth2 with PKCE (plus dynamic client registration for MCP) and client credentials, all sealed. `cred_…` handles are bound to (user, app id, host pattern); only the gateway resolves them. The add flow picks the auth kind (declared methods first, then every other kind) and the host opens its own secure sheet; the app never sees a value.
7. **Lifecycle.** Disconnect sends `integration.revoke` with the tap's gesture token; the shell shows its confirmation sheet first (a cancel answers `user.cancelled`). Team admins may disconnect team-shared connections (audited; the app says so, and tells members that the creator or a team admin is needed). Sharing: the creator or admins. Sign in again keeps the id, sharing and rules. Google Calendar and Gmail show as "Coming". `integration.changed` arrives on the user stream; the app subscribes once and re-reads.

### Still mocked (proposed operations)

| Mock | Shape the app assumes | Owner |
| --- | --- | --- |
| `integration.list` additions | `viewer {user, team_admin}`, `limit {used, max}`; per record `catalog`, `auth {kind}`, `mcp_exposed`, and `catalog.changed {at, feed_item, previous_digest}` (field name is this app's choice) | ConnectionDO |
| `integration.policy.get` | `generic_hosts: string[] \| null`; `allowed_providers` may list generic kinds | ConnectionDO |
| `integration.tools.list` | `{namespace, tools: ToolEntry[], rules: PolicyRule[], catalog}` | gateway + ConnectionDO (team) + UserDO (user) |
| `integration.tools.policy.set` | `{connection, owner: user \| team, pattern, action \| null}` -> `{rules}` | UserDO / ConnectionDO |
| `integration.catalog.preview` | `{source: {url}}` -> `{catalog}`; errors `egress.*`, `catalog.too_large` with `details.host` | gateway |
| `integration.connect` (generic) | adds `source`, `catalog {digest, namespace}`, `auth {kind, headers?, query?, scopes?, dynamic_registration?}`; the host opens the secure sheet | ConnectionDO + shell |
| `integration.reauth`, `integration.share` | `{connection}` / `{connection, sharing}` -> record | ConnectionDO |
| `integration.revoke` for apps | today in the app "never" list; contract: gesture + shell confirmation sheet, `user.cancelled` on cancel | shell + ConnectionDO |
| `integration.mcp.set` | `{connection, exposed}` -> record | ConnectionDO |
| `ui.open` `cmux.feed/1` | `{interface: "cmux.feed/1", target: {item}}` opens the feed item | shell |
| `app.pane.open` | `{kind}` opens this app's pane | shell |
| event `integration.changed` | `{connection}` on the user stream | ConnectionDO outbox via the session |

MCP names shown in the detail screen are computed locally over the connections whose tools this session loaded; the gateway assigns the real names over all of the principal's connections with the same function, so they differ only in a cross-connection collision.

## Code placement

The pure core lives in `libs/integrations-core/` (`@cmux/integrations-core`, MIT), so the gateway (authoritative ingestion at connect and refresh, policy resolution at call time) and this app (local preview and display) run one implementation. A rule set in the preview must match the tool the gateway runs, so tool paths and defaults cannot fork. The app imports it by name through `tsconfig.json` `paths`; `pack.ts` bundles it. The package README says why `libs/` (not `backend/`, which is BSL, and not a top-level `packages/`, which collides with `Packages/` on case-insensitive file systems) and how the backend adopts it.

The gateway adds what the app must not do: YAML parsing, fetching specs with the SSRF guard after DNS and redirects (the package's `egress.ts` is only the URL-text pre-check), the Streamable HTTP MCP client (no stdio), the `/v1/mcp` endpoint (names from `mcp-names.ts`), and invocation (executor `plugins/openapi/src/sdk/invoke.ts` is the next candidate to adapt into the package, under the same NOTICE).

## Manifest v2

`cmux-app.v2.json` is the manifest v2 that the daemon's app supervisor loads; it passes the one validator (`cmux-tui/crates/cmux-app-manifest`). It declares the same app as `cmux-app.json`: `runtime.main` `dist/main.js`, `cmux.section/1` (`renderSection`) and `cmux.pane/1` (`renderPane`); `files` ships `LICENSE-executor`, and the catalog fragment `catalog/integrations-catalog.json`. Every v1 command is one catalog op of family `integrations` (owner `app:cmux/integrations`, `export` names the JS function, CLI `apps run cmux/integrations <verb>`, palette title only for palette commands, MCP as v1 exposed it). The DEV/NIGHTLY `variant` setting is the `variants` block. `cmux-app.json` stays for today's in-app runtime.

The v2 schema cannot hold these parts of the app, so the manifest leaves them out:

1. `cmux.credential.provider/1` and `cmux.feed.source/1`: the app has no `pickCredential` or `renderFeedItem` export yet, so it does not claim them.
2. `notices`: no manifest field; the license file is listed in `files` instead.
3. Connection and credential handles (`conn`, `cred`): `handles` accepts only root, host, credential, document and diff, and the app does not ask for a handle today.

Platform gaps found by the earlier v2 sketch (still open):

- No secure input in the scene vocabulary: credential collection must stay a shell sheet (proposed integration.connect host behavior), never a TextField in an app.
- No URL-open host capability for OAuth approval pages from an app with a gesture.
- No Table or Segmented control in V7's component list: the Allow / Ask / Block control is three tappable Texts.
- cmux.feed.source/1 has no schema yet for action buttons that answer with a policy change (Always allow).

## Platform gaps (most important first)

1. No secure input and no URL open for apps: the secret sheet and the OAuth approval page must be host behavior on `integration.connect` (contract item 6); the app says when the host did not open the page.
2. `integration.revoke` is still in the app "never" list; Disconnect shows `scope.missing` until the shell's gesture-plus-confirmation path exists (contract item 7).
3. The preview host's scope table does not list the existing `integration.*` ops (fixtures add them under `scopes`); without that the app sees `scope.missing` for `integration.list`.
4. No typed change stream in `cmux-app.d.ts`: the app listens to `integration.changed` by name.
5. A function child that returns a function (not a view) is dropped silently, with no log line.
6. View modifiers are single props: a second `.padding()` replaces the first, so outer margins need a wrapper node. `Button` ignores `.font`.
7. No segmented control or toggle and no multi-line text field (specs paste as one line; Allow / Ask / Block and Off / On are tappable texts).
8. No pane input: a pane mount has no `connection`; commands set a shared route instead.
9. `untrack` is a runtime global but missing from `cmux-app.d.ts` (`src/globals.d.ts` declares it).
10. `x-cmux-devOnly` is not honored; strings are bundled from `strings/<lang>.json` until hosts pass them to `cmux.t`.

## Layout and checks

`src/model/` state and owner calls; `src/views/` scene; `src/main.ts` exports; ingestion and policy come from `@cmux/integrations-core`. Build: `bun first-party-apps/build.ts integrations`. Tests: `bun test first-party-apps/integrations/test` (FakeHost tests per variant and flow, l10n coverage) and `bun test libs/integrations-core/test` (ingestion and policy on fixtures under `libs/integrations-core/test/fixtures/`). Preview fixtures: `bun first-party-apps/integrations/preview/make-fixtures.ts` (`connections`, `catalog`, `taskboard`, `docs`, `reauth`, `admin`, `empty`, `limit`, `managed`, `egress`, `missing`). No test makes a network call.
