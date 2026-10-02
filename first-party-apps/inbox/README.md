# Inbox (`cmux/inbox`)

One triage list of everything that needs you: cmux notifications, agents that wait for input or just finished, and GitHub work items (review requests, your pull requests with failing checks, mentions) through the integration gateway. Each item can be opened, marked done, or snoozed; waiting agents can get a quick reply.

An agent's notifications fold into its item, so a permission prompt shows once, not as an agent row plus a notification row. Items sort by urgency (agent waiting for input, then failing checks and error notifications, then review requests, finished agents, warnings, mentions, idle agents), then by age. Done and read state is stamped with the item's last change, so an item comes back when it changes again (a new notification for that agent, a new push to that pull request).

Build: `bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/inbox`. Validate: `bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/inbox`. Test: `bun test first-party-apps/inbox/test`. Preview fixtures: `bun first-party-apps/inbox/test/fixtures.ts --write`.

## Contributions

| Contribution | Export | What it does |
| --- | --- | --- |
| sidebar section `inbox` | `renderInbox` | the main surface, in the selected variant |
| status item `badge` | `renderStatus` | tray glyph and unread count (warning tone while an agent waits); click opens the most urgent unread item; menu lists the top 8 |
| pane kind `pane` | `renderPane` | the same surface in wide layouts (the platform does not mount pane kinds yet; the preview harness renders it) |
| commands | `openInbox`, `markAllRead`, `nextItem`, `previousItem`, `openItem {id?}`, `markDone {id?}`, `snooze {id?, minutes?}`, `list {source?, unreadOnly?, includeSnoozed?}`, `refresh`, `cycleVariant` | palette entries; with `mcp:expose` each is an MCP tool. `id` defaults to the selected item, so `markDone`, `snooze` and `openItem` double as keyboard triage commands |
| MCP server `tools` | commands | `list` returns JSON (`id, source, kind, title, detail, unread, updated_at, snoozed_until, workspace, terminal_id, url, repo, number, level`) |

Item ids are stable: `agent:<agent id>`, `notification:<notification id>`, `github:<owner/repo>#<number>`.

## Scopes

| Scope | Why |
| --- | --- |
| `notification:read` | list cmux notifications |
| `notification:write` | `notification.ack` when you open, read or finish an item |
| `agent:read` | agents that are blocked, done or idle |
| `terminal:read` | name an agent by its terminal, find its tab, and show the last lines of its screen in the detail |
| `workspace:read` | workspace names, only while grouping by workspace |
| `workspace:write` | `tab.focus` when you open an agent or notification |
| `actions:run` | `openBrowser` for pull requests |
| `integration:github:read` (optional) | GitHub items through the gateway; the token never enters the app |
| `terminal:execute` (optional) | quick reply: types your text and Return into the agent's terminal. This can run commands, so it is opt-in; without it the reply field explains how to allow it |
| `mcp:expose` (optional) | agents can list items and mark them done or snoozed |

## Settings

`variant` (dev only), `groupBy` (`source` or `workspace`), `includeDoneAgents` (true), `includeIdleAgents` (false), `maxAgeDays` (7; notifications and mentions older than this are hidden, agents never are), `githubReviewRequests`, `githubFailingChecks`, `githubMentions` (true), `githubRefreshMinutes` (10). Filters (source, unread only, only my work), grouping override and the triage ledger live in app storage.

"Only my work" keeps agents, notifications and your own pull requests and hides requests from others (review requests, mentions).

## Variants (dogfood; `variant` setting or "Next Inbox Variant")

| Variant | Design |
| --- | --- |
| `grouped` (default) | dense native rows under source headers (or workspace and repository headers); a click opens; actions in the row menu; one filter pull-down |
| `focus` | icon chips for source, unread and mine; a flat urgency-ordered list where a click selects; a detail area with the agent's screen or the failing check names, Open / Done / Snooze, and quick reply. Side by side in a pane |
| `card` | one item at a time with "3 of 8", Open / Done / Snooze / Skip and quick reply |

Recommendation: `grouped` for the sidebar, because it reads as native sidebar rows and opens in one click. Strongest objection: triage actions (done, snooze) hide in the right-click menu, so clearing many items is slower than in `card`, and the context that explains an agent's question is not visible without opening its tab.

## No polling

Notifications, agents and terminals use `cmux.live` (re-read on `notification.changed`, `agent.changed`, `terminal.changed`). Snooze wake-up is one one-shot `cmux.timer.after` for the earliest wake. GitHub is the one repeating timer (`githubRefreshMinutes`, default 10): it has no push channel to apps yet. The timer belongs to the mount (cleared on unmount), skips a refresh when the last one is recent, and stops itself when GitHub is not granted or not available.

## Proposed operations

| Name | Params | Result | Owner | Risk | Scope | Invalidated by | Why existing ops do not suffice |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `notification.changed`, `agent.changed` payloads | event | `{kind: upsert\|delete, id, value?}` | session host | read | `notification:read`, `agent:read` | itself | the streams exist for `cmux.live`, but with no payload every change re-reads the whole list in every mount |
| `integration.changed` | event `{provider}` | | integration gateway (cloud, fed by the GitHub App webhooks) | read | `integration:<provider>:read` | itself | replaces the GitHub refresh interval |
| `app.badge.set` | `{contribution?, count \| null, tone?}` | `{}` | app supervisor; clients render it | mutate-own | none | | section header badge, and an app-level badge for the Dock or menu bar; today the count can only render inside the app's own scene |
| `app.pane.open` | `{contribution, placement?}` | `{tab_id}` | workspace store | mutate-own (moves focus only in a user turn) | `workspace:write` | | "Open Inbox" needs to open the pane kind as a tab |
| `app.settings.set` | `{key, value}` | `{}` | config layer | mutate-own (the app's own settings) | none | `__cmuxAppSetSettings` | "Next Inbox Variant" cannot write the `variant` setting; it stores an override in app storage instead |
| `integration.request` result shape | `{provider, method, path, body?}` | the response JSON body; HTTP errors reject with `integration.http {status}` | gateway | read for GET | `integration:<provider>:read` | | the host answers `operation.unsupported` today; the app also accepts a `{status, body}` envelope |
| `notification.ack` for apps | `client_id` | | session host | mutate-own | `notification:write` | `notification.changed` | the app acks with `client_id = app:cmux/inbox` so its read state is shared by every client through the daemon's per-client ledger. Proposal: for app actors the host stamps `client_id` with the app principal, so an app cannot ack as another client |
| `workspace_id` and `tab_id` on `AgentSnapshot` and `NotificationSnapshot` | | two more fields | session host | read | `agent:read`, `notification:read` | | grouping by workspace needs four extra list reads to walk terminal, tab, pane, screen, workspace |

## Platform gaps

1. User-invoked commands (palette, keybinding) run with origin `script`, so "Next Inbox Item" and "Open Selected Inbox Item" cannot move focus. Origin `user` should cover any user-initiated command run.
2. A tap handler's user turn across `await` is undefined; the app issues `tab.focus` synchronously in the tap when the terminal's tab is known (from `terminal.list`), and falls back to `terminal.get` then `tab.focus`, which may not move focus.
3. No section header badge or accessories; the unread count renders inside the section's own toolbar.
4. No keyboard events in scenes and no default keybindings in the manifest; keyboard triage relies on commands the user binds.
5. No app lifecycle hook (`onCleanup`/unmount) and no way to share one subscription across mounts: each mounted surface runs its own reads, and workspace reads are scoped to a `ForEach` row that exists only while grouping by workspace. Also no visibility signal to pause timers when a mounted surface is hidden.
6. No API for an app to know its granted scopes; optional features (GitHub, quick reply) are detected by calling and catching `scope.missing`.
7. Menu items have no checked state and the typed API cannot set a menu item symbol, so the filter menu shows the current source as disabled.
8. Stacks have no `alignment` prop; wide layouts end each column in a `Spacer` to stay top-aligned.
9. No locale in init or mount context and no app i18n API; `t()` reads `Intl` when the engine has it.
10. `x-cmux-devOnly` on a settings property is not honored yet.
11. No per-command MCP exposure flag (UI-only commands such as `cycleVariant` become tools too).
12. Synced app storage (`storage:synced`) does not exist yet, so done and snooze state is per machine.
13. `integration:github:read` allows only GET, which blocks GraphQL reads (one query could fetch check states for every pull request); a read-only `integration.graphql` or a query-only POST rule would help.
14. Relative ages update only when data changes; there is no coarse, visibility-paused clock signal.
15. The typings omit `CmuxError`'s constructor and `untrack`, both present at runtime.
