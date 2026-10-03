# CodeRouter (first-party cmux app prototype)

Setup and status for CodeRouter, cmux's hosted model router (`web/services/coderouter/README.md`, `plans/cmux-next/coderouter.md`). The app shows whether you are signed in, your scope (personal or a team) and router health; the provider accounts cmux found on this Mac and the ones CodeRouter holds, private or shared; your `crk_` API keys; usage and spend per account, model or key; the failover order; and a test request. A first-run setup takes a new user from "what do I have" to a passing test in five steps.

The app never sees a secret. It passes provider ids, account ids and opaque handles. cmux reads local sign-ins, asks for pasted keys in its own secure field, shows a new API key in its own sheet, writes it to the clipboard, and sends the test prompt with its own credential.

## Contributions

| Contribution | Kind | What it does |
| --- | --- | --- |
| `coderouter` | sidebar section | Scope and health, today's usage, accounts ready, key count. In the `checklist` variant it also holds the setup checklist until setup is done. |
| `health` | status item | Health dot and "1.8M tok · $6.42" for today; menu: Open, Run Test, Set Up. |
| `dashboard` | pane kind | Status, accounts, failover order, usage, API keys, test. |
| `onboarding` | pane kind | First-run setup in the variant's layout. |
| `open`, `connectAccount {provider?}`, `createKey {label?}`, `runTest`, `startOnboarding`, `cycleVariant` | commands | Palette (and CLI/MCP when the platform exposes app commands). `connectAccount` with no provider connects the best account found on this Mac. |

Settings: `usageWindow` (24h, 7d, 30d), `statusShowsUsage`, and two dev-only keys, `variant` and `language`.

## Scopes

| Scope | Why |
| --- | --- |
| `coderouter:read` | Status, detection (presence only), account list, key names, usage, failover order. |
| `coderouter:write` | Ask cmux to connect, share or remove an account, set the failover order, and route cmux agents through CodeRouter. |
| `actions:run` | Open the Accounts screen, sign in, run a provider's own login in a terminal tab, and the fallback for connect and remove on builds without the proposed ops. |
| `coderouter:execute` (optional) | Send one tiny test prompt. It spends a few tokens. |
| `coderouter:control` (optional, restricted) | Create and revoke API keys. The intended name is `coderouter:keys`, which the scope grammar rejects (see gaps). Only first-party or reviewed apps should be able to hold it. |

App storage needs no scope. The app keeps setup progress (`onboarding`) and the last test result (`lastTest`, model, latency, request id) there. Nothing stored is secret.

## Variants

Pick with the dev-only `variant` setting or "Next CodeRouter Variant" in the palette.

| Variant | Onboarding | Dashboard |
| --- | --- | --- |
| `checklist` (default, recommended) | Five rows in the sidebar section; the open step expands in place with its action, Skip and Done. Hidden once done or after Hide. | One scrolling pane of sections. |
| `wizard` | A pane with one step per screen, progress dots, Back, Skip Setup, Skip, Continue. Steps the data already proves (an account connected, a key exists) are skipped. | One scrolling pane of sections. |
| `tabs` | A Setup tab with all five steps on one page and a progress bar. | A pane with tabs: Overview, Accounts, Keys, Usage, Routing, Setup. Opens on Setup while setup is pending. |

Recommendation: `checklist`. It works on today's platform (sidebar sections mount; panes do not yet), it is resumable without opening anything, and every step is one tap from where the user already looks. Strongest objection: it takes a lot of sidebar height while setup is open and the 300 pt column truncates account labels; the wizard reads better for a true first run.

## Setup flow

Detect (cmux lists sign-ins and keys found, as `acct_…` handles with plan names or shortened labels, never emails) -> Connect (one Connect per recommended account, agent sign-ins first; Sign In Again for expired ones; Add with a Key for paste-only providers) -> Share (team scope only; private by default; Share or Share All in one call) -> Use (route cmux agents through CodeRouter, or create a key that cmux shows once) -> Test (one tiny prompt, model, latency, account). A step completes when the user finishes it or when the data shows it is done. Progress lives in app storage, so setup resumes on any surface. Skip moves on; Skip Setup or Hide closes setup; "Set Up CodeRouter" reopens it. The reducer is pure (`src/onboarding.ts`) and has a randomized invariant test.

## Proposed operations

None of these exist yet. The app calls them with `cmux.call` and shows "Not available in this cmux build" when they are missing; connect and remove fall back to the existing `accounts.connect` / `accounts.remove` actions. All `coderouter.*` writes emit `coderouter.changed`; detection emits `coderouter.detect.changed`. "User" means the op must run with origin = user (inside a tap or command turn), checked by the owner.

| Operation | Params -> result | Owner | Risk | Scope | User | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- |
| `coderouter.status` | `{}` -> `{signed_in, user {name}, scope {kind, team_id, team_name}, health, agents_routed, usage_today}` | native accounts service + cloud control plane (`/api/coderouter/health`) | read | `coderouter:read` | no | No app op reads sign-in, team or router health. |
| `coderouter.detect` | `{}` -> `[{provider, name, status, account?, label?, plan?, linkable, source?}]` (`account` is an `acct_…` handle, `label` a redacted display, never an email) | native accounts service (presence-only detection) | read | `coderouter:read` | no | Detection is native only; the socket `accounts.list` is not in the app catalog. |
| `coderouter.accounts.list` | `{}` -> `[{id, provider, name, label, state, visibility, mine, cooldown_until_ms?}]` | cloud control plane (via the native client) | read | `coderouter:read` | no | No app op lists linked accounts. |
| `coderouter.accounts.connect` | `{provider}` -> `{status: connected or cancelled, account?}` | native accounts service (reads the local credential or shows its secure paste field and the Codex confirmation), then cloud | mutate-shared, reads a local credential | `coderouter:write` | yes | `accounts.connect` runs but returns no outcome to an app. |
| `coderouter.accounts.remove` | `{account}` -> `{removed}` | cloud; host confirms | mutate-shared, destructive | `coderouter:write` | yes, confirm | Same as connect. |
| `coderouter.accounts.share` | `{accounts: [id], visibility: team or private}` -> `[account]` | cloud (`PATCH .../sharing`) | mutate-shared | `coderouter:write` | yes | No action exists. A list makes "Share all" one user action. |
| `coderouter.keys.list` | `{}` -> `[{id, label, prefix, created_at_ms, last_used_at_ms, revoked, usage_7d}]` | cloud | read | `coderouter:read` | no | No app op. Metadata only. |
| `coderouter.keys.create` | `{label, present: sheet or none}` -> `{key, handle, handle_expires_at_ms}` | cloud mints; the native host keeps the plaintext in memory and shows it once in its own sheet | mutate-shared (team credential) | `coderouter:control` (restricted) | yes, confirm | A plaintext return would put the key in the app VM. |
| `coderouter.keys.revoke` | `{key}` -> `{revoked}` | cloud; host confirms | mutate-shared, destructive | `coderouter:control` | yes, confirm | No app op. |
| `ui.secret.reveal` | `{handle}` -> `{shown}` | native client UI | read (host display only) | the scope that minted the handle | yes | General primitive: show a host-held secret without the app seeing it. |
| `clipboard.writeSecret` | `{handle}` -> `{copied, clears_at_ms}` | native client (concealed pasteboard type, clears after 60 s) | mutate-own | the scope that minted the handle | yes | `clipboard:write` takes app-provided text, which a secret must never be. |
| `coderouter.usage.get` | `{window: 24h, 7d or 30d, group_by: account, model or key}` -> `{window, group_by, totals, rows}` | cloud (usage ledger) | read | `coderouter:read` | no | No app op. |
| `coderouter.route.get` | `{surface: responses or messages}` -> `{surface, strategy: ordered or headroom, order: [{account, label, name, state, cooldown_until_ms}]}` | cloud | read | `coderouter:read` | no | No app op. |
| `coderouter.route.order.set` | `{surface, accounts: [id]}` -> route | cloud; needs a stored priority (today the router picks by headroom) | mutate-shared | `coderouter:write` | yes | No server field yet. |
| `coderouter.route.test` | `{surface: auto}` -> `{ok, model, account_label, provider_name, latency_ms, request_id, error?}` | native host sends a fixed tiny prompt with its own route token; host rate-limits | execute, send-external (spends tokens) | `coderouter:execute` | yes | An app with `net:` cannot authenticate without a token in the VM. |
| `coderouter.agents.set` | `{enabled}` -> `{enabled}` | config layer + native (cmux injects a route token into agents it launches) | mutate-own | `coderouter:write` | yes | No op or setting exists. |
| `app.pane.open` | `{kind}` -> `{tab}` | app supervisor + client | mutate-own (opens a tab, moves focus) | implicit for the app's own pane kinds | yes | Pane kinds cannot be opened by their app. |
| `app.settings.set` | `{key, value}` -> `{}` | config layer | mutate-own (the app's own settings) | implicit | yes | `cycleVariant` can only switch for the session. |

## Platform gaps

1. No secret primitives. There is no host secure input, reveal sheet or secret clipboard write, and spec 6.5 says account and credential ops are never callable by apps. This app needs the handle model above and an explicit restricted-scope carve-out for first-party and reviewed apps.
2. Pane kinds do not mount and an app cannot open its own pane (`app.pane.open`). The dashboard and the wizard render only in the preview harness; `open` falls back to the Accounts screen.
3. origin = user ends at the first `await` in a tap handler. A flow that reads, then writes, loses user origin. The proposed ops take lists (`accounts.share`) or do the follow-up themselves (`keys.create` with `present`).
4. The runtime refuses ops outside its allowed list locally with `scope.missing` and no `details.scope`, so an app cannot tell "this build has no such op" from "scope not granted". Unknown ops should answer `operation.unsupported`.
5. `actions:run` lets any app run credential actions (`accounts.connect`, `accounts.remove`, sign-in) with no account scope. Actions need their own risk and scope, and must require origin = user.
6. The scope grammar has no level for minting credentials (`coderouter:keys` is invalid) and no marker for scopes only first-party or reviewed apps may hold. The `storage:local` scope from `scopes.json` is also rejected by the manifest grammar (storage is always allowed, so this app does not declare it).
7. `x-cmux-devOnly` is not honored, and there is no `app.settings.set`.
8. No app localization API and no locale in the mount context. The app has `t()` tables and a dev-only `language` override.
9. A function child tracks every signal read while it builds, so careless reads rebuild whole subtrees and reset local state. `untrack` exists in the runtime but not in `cmux-app.d.ts`. The app uses `computed` gates to narrow rebuilds.
10. Missing nodes: toggle, segmented control, secure field, sheet, table, chart, `frame` alignment. Buttons ignore `.font`. Usage bars are capsules; tabs and windows are tappable text.
11. The reference `FakeHost` keeps removed subtrees in its node map; the tests walk the tree from the root.

## Develop

```bash
bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/coderouter
bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/coderouter
bun test first-party-apps/coderouter/test
```

`preview/*.json` are fixtures per state, for any variant: `dashboard` (team, accounts, keys, usage), `onboarding` (first run, nothing connected), `onboarding-mid` (one private account), `empty` (personal scope, nothing found), `error` (router unreachable), `signedout`, `unsupported` (today's platform). Fixture data is invented; no real accounts, emails or keys.
