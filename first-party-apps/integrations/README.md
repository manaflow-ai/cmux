# Integrations (`cmux/integrations`)

Connect GitHub, Linear, Slack, Google Calendar, Gmail or any OpenAPI, GraphQL or MCP API; see each connection's health; share it with your team; sign in again; disconnect; and choose per tool whether agents and automations may run it (Allow), must ask you first (Ask) or never run it (Block).

The app is a UI over the backend's one integration model (spec `integrations.md`, protocol `integrations.ts`): `Connection` records owned by `ConnectionDO`, credentials held only by the gateway, the team's `TeamIntegrationPolicy`, sharing `private | team`. The app keeps no second store: it renders what `integration.list` and `integration.policy.get` return and re-reads on change events. It never sees a token; a credential is an opaque `cred_…` handle that only the gateway resolves.

## Credits

The generic import (OpenAPI, GraphQL and MCP ingestion, tool paths, auth-method detection) and the policy pattern matcher and defaults live in the MIT package `@cmux/integrations-core` (`libs/integrations-core/`), adapted from [executor](https://github.com/UsefulSoftwareCo/executor), MIT License, Copyright (c) 2026 Rhys Sullivan. The package's `NOTICE` lists the adapted files with their upstream paths, and each adapted file starts with the same credit. `pack.ts` bundles the package into `dist/main.js`, so this app ships `LICENSE-executor` as its notice. The app shows the credit under the importer and on generic connections. No telemetry, billing or registry-fetch code was copied.

## Contributions

| Id | Kind | What |
| --- | --- | --- |
| `integrations` | sidebar section | connections that need action, then "N connected" |
| `pane` | pane kind | the main surface (three variants), connection detail, connect gallery, API importer |
| `openIntegrations` | command (palette, section) | opens the pane, optionally on one connection |
| `connect` | command (palette) | starts connecting a first-class provider |
| `importApi` | command (palette) | previews a spec URL or JSON in the importer |
| `cycleVariant` | command (palette, DEV/NIGHTLY) | next design variant |

No MCP tools: connecting needs a human at the provider, and agents already reach `integration.list` and provider ops through the backend catalog.

## Scopes

| Scope | Why |
| --- | --- |
| `integration:read` | list connections, their tools and the team policy |
| `integration:write` (optional) | connect, sign in again, share, disconnect, change a tool's policy, each on a click |
| `workspace:write` (optional) | open the pane from the palette or sidebar |

## Variants (DEV/NIGHTLY setting `variant`, palette "Next Integrations Variant")

| Variant | Design |
| --- | --- |
| `connections` (default) | list of connections, attention first; a row opens detail: health with Sign In Again, account, sharing, permissions, team policy line, Share / Disconnect, then the connection's tools with Allow / Ask / Block |
| `gallery` | onboarding first: every provider with Connect (or why not: not set up, blocked by team), "Any API" cards for OpenAPI, GraphQL and MCP, then your connections |
| `catalog` | every tool of every active connection with its policy, a filter field, and where each action comes from (default, your rule, team rule) |

Recommendation: `connections`. It matches how people think about integrations (an account they linked), and it puts health and re-auth first. Strongest objection: per-tool policy sits one level down, so an admin who asks "what may agents do?" must open each connection; `catalog` answers that question directly. A likely final shape is `connections` with a Tools tab that is the `catalog` view.

## Policy defaults (from the spec, before any rule)

Reads Allow, changes Ask, destructive Block (decided): OpenAPI GET/HEAD/OPTIONS, GraphQL queries and MCP `readOnlyHint` tools Allow; OpenAPI POST/PUT/PATCH, GraphQL mutations and un-annotated MCP tools Ask; OpenAPI DELETE, GraphQL mutations named with a destructive verb and MCP `destructiveHint` tools Block. First-class provider ops use the same mapping on the backend op's risk (read and mutate-own Allow, send-external and mutate-shared Ask, destructive and money Block). The full table, the rule patterns and the grant mapping are in `libs/integrations-core/README.md`; `defaultActionFor` there is the single source.

## Proposed operations

| Op | Params | Result | Owner | Risk | Scope | Events | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `integration.tools.list` | `{connection}` | `{namespace, tools: ToolEntry[], rules: PolicyRule[], catalog: {title, version, digest, refreshed_at}}` | gateway (catalog store) + ConnectionDO/UserDO (rules) | read | `integration:read` | `integration.changed` | no catalog of a connection's tools exists |
| `integration.tools.policy.set` | `{connection, owner: user \| team, pattern, action \| null, expected_revision?}` | `{rules}` | user rules: UserDO; team rules: ConnectionDO (admins) | mutate-own (user), mutate-shared (team) | `integration:write` | `integration.changed` | per-tool policy has no home; grants are per op class only |
| `integration.catalog.preview` | `{source: {url} \| {document}, credential?: cred_…}` | `{catalog}` | gateway | read (fetches the URL with an SSRF guard) | `integration:read` | | private specs need a credential the app must not see |
| `integration.connect` (extended) | adds `provider: openapi \| graphql \| mcp`, `source`, `catalog: {digest, namespace}`, `auth: {kind, headers?, query?, flow?}` | `{connection, authorize_url?, opened?}` | ConnectionDO; the host collects the secret in its own sheet | mutate-shared, origin user | `integration:write` | `integration.changed` | generic connections in the same record (question 1) |
| `integration.reauth` | `{connection}` | `{connection, authorize_url, opened?}` | ConnectionDO | mutate-shared, origin user | `integration:write` | `integration.changed` | keeps id, sharing and tool rules; a new connect would lose them |
| `integration.share` | `{connection, sharing}` | `Connection` | ConnectionDO (creator only) | mutate-shared | `integration:write` | `integration.changed` | sharing is set only at connect today |
| `integration.revoke` (exists) | `{connection}` | `Connection` | ConnectionDO | destructive | `integration:write` | `integration.changed` | in the app "never" list; propose: allowed with a gesture plus a shell confirmation |
| `integration.catalog.refresh` | `{connection}` | `{digest, added, removed, changed}` | gateway | mutate-shared | `integration:write` | `integration.changed` | specs change; rules survive by address |
| `integration.call` | `{connection, tool, args, idempotency_key}` | provider result | gateway, same ledger as provider ops | the tool's op class | per tool policy | | how agents, automations and the MCP endpoint run generic tools (not called by this app) |
| `credential.request` | `{kind, host?, label}` | `{credential: cred_…}` | shell sheet + gateway | mutate-own, gesture | `credential:request` | | other local apps (HTTP or DB client) ask for a credential (`cmux.credential.provider/1`) |
| `app.pane.open` | `{kind, input?}` | `{pane}` | shell | mutate-own, gesture | `workspace:write` | | open this app's pane from a command |
| host behavior | `integration.connect` / `reauth` called by an app with a gesture | host opens `authorize_url`, adds `opened: true` | shell | | | | apps cannot open URLs; approval must happen in the user's browser |
| event | `integration.changed {connection}` (typed `integration.watch`) | | ConnectionDO outbox via the session | | `integration:read` | | no app-visible change stream today |
| `integration.list` additions | | per connection `capabilities {revoke, share, reauth}` and `catalog` summary | ConnectionDO | read | | | the app cannot tell who it is, so it cannot hide Disconnect for teammates' connections |

## Code placement

The pure core lives in `libs/integrations-core/` (`@cmux/integrations-core`, MIT), so the gateway (authoritative ingestion at connect and refresh, policy resolution at call time) and this app (local preview and display) run one implementation. A rule set in the preview must match the tool the gateway runs, so tool paths and defaults cannot fork. The app imports it by name through `tsconfig.json` `paths`; `pack.ts` bundles it. The package README says why `libs/` (not `backend/`, which is BSL, and not a top-level `packages/`, which collides with `Packages/` on case-insensitive file systems) and how the backend adopts it.

The gateway adds what the app must not do: YAML parsing, fetching specs with an SSRF guard, the MCP client for remote servers (no stdio), and invocation (executor `plugins/openapi/src/sdk/invoke.ts` is the next candidate to adapt into the package, under the same NOTICE).

## Questions for the backend lead

1. Generic connections in the same `Connection` record: extend `IntegrationProvider` with `openapi | graphql | mcp`, add `catalog {kind, title, version, digest, tools, source_url}` and `auth {kind}`, account key `openapi:<host>:<namespace>`? Do they count toward `MAX_CONNECTIONS = 50`? Recommend yes to all: one list, one sharing model, one revoke.
2. Imported tool catalogs: where do they live and how are they versioned? Proposal: content-addressed blob (R2 or DO SQLite) keyed by digest; the connection stores `{digest, source, refreshed_at}`; `integration.catalog.refresh` and a server-side scheduled check (allowed off-device) re-ingest and post a feed notice with added and removed tools; new tools start at their defaults; rules survive by address and become inert when a tool disappears.
3. Per-tool policy vs grants vs `TeamIntegrationPolicy`: team rules in ConnectionDO next to the policy (single writer), user rules in UserDO, resolution in the gateway (most restrictive wins). Allow = approval `none`, Ask = `per_call`, Block = no grant. Should `allowed_providers` list generic kinds, and should the policy gain a host allowlist for generic APIs? (Decided: destructive defaults to Block.)
4. Gateway execution of generic calls: `integration.call` through the same external-effect ledger as `github.issue.comment` (decided keys replay, `mutation.indeterminate` after a send), egress limited to the spec's servers, no private addresses, response size caps, redacted errors. Agree? Who owns MCP sessions to remote servers (one per connection in the ConnectionDO)?
5. Code placement and NOTICE (decided): MIT package `libs/integrations-core/` outside the BSL directories, with `LICENSE` and `NOTICE`; the backend depends on it (steps in its README).
6. Credential types: API key (header or query), bearer, basic, custom header sets, OAuth2 authorization code (with PKCE; dynamic client registration for MCP servers), OAuth2 client credentials. All sealed with the existing envelope. For local apps: is a `cred_…` handle always resolved by the gateway (calls go through `integration.call` or a gateway-proxied fetch), or may the Mac host inject a secret into a local request? Recommend gateway only.
7. One MCP endpoint per user or team that exposes the whole catalog (`/v1/mcp` scoped by session or install, tools named `<namespace>__<path>` within MCP's 64-character limit, Ask tools answered through the feed or MCP elicitation, Block tools hidden): which process hosts it (API Worker route or a DO), and does it replace per-provider vendor MCP for agents?
8. `integration.revoke` is in the app "never" list and only the creator may revoke. May an app call it with a gesture and a shell confirmation? May team admins revoke a teammate's team-shared connection?
9. Sharing after connect: add `integration.share`, creator only?
10. Re-auth: add `integration.reauth` that keeps id, sharing and rules?
11. `IntegrationProvider` lacks `google_calendar` and `gmail` (spec "first providers"); the app shows them as "Not set up yet" from `providers[].configured`.
12. A change stream for apps: will the ConnectionDO outbox (`connection.upsert`) reach clients as `integration.changed`?

## Platform gaps (most important first)

1. No secure input and no URL open for apps: the secret sheet and the OAuth approval page must be host behavior on `integration.connect` (proposed above); the app says when the host did not open the page.
2. `integration.revoke` is never grantable to apps; Disconnect fails until a gesture-plus-confirmation path exists.
3. The preview host's scope table does not list the existing `integration.*` ops (fixtures add them under `scopes`); without that the app sees `scope.missing` for `integration.list`.
4. No typed change stream: the app listens to the guessed `integration.changed`.
5. A function child that returns a function (not a view) is dropped silently, with no log line.
6. View modifiers are single props: a second `.padding()` replaces the first, so outer margins need a wrapper node. `Button` ignores `.font`.
7. No segmented control and no multi-line text field (specs paste as one line).
8. No pane input: a pane mount has no `connection`; commands set a shared route instead.
9. `untrack` is a runtime global but missing from `cmux-app.d.ts` (`src/globals.d.ts` declares it).
10. `x-cmux-devOnly` is not honored; strings are bundled from `strings/<lang>.json` until hosts pass them to `cmux.t`.

## Layout and checks

`src/model/` state and owner calls; `src/views/` scene; `src/main.ts` exports; ingestion and policy come from `@cmux/integrations-core`. Build: `bun first-party-apps/build.ts integrations`. Tests: `bun test first-party-apps/integrations/test` (FakeHost tests per variant and flow, l10n coverage) and `bun test libs/integrations-core/test` (ingestion and policy on fixtures under `libs/integrations-core/test/fixtures/`). Preview fixtures: `bun first-party-apps/integrations/preview/make-fixtures.ts`. No test makes a network call.
