# Inbox (`cmux/inbox`)

A view on the cmux feed. The feed is one system for notifications and requests: items that may or may not need a response, owned by a per-user owner synced to every device (Mac, iPhone, web), with a local owner as fallback. Agents, apps, runs and integrations post items. GitHub review requests and failing checks arrive as feed items posted by the integration side; this app does not call GitHub and does not merge sources itself.

The app keeps no item model. Order, grouping, counts, seen, done and snooze state, and snooze wake-ups belong to the feed owner. The app lists items with the filters the user picks, re-lists when the owner sends `feed.changed`, and sends the user's actions (open, mark seen or done, snooze, respond) back to the owner. It stores only view preferences (filters, grouping, the dogfood variant) in app storage.

Build: `bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/inbox`. Validate: `bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/inbox`. Test: `bun test first-party-apps/inbox/test` (FakeHost with an in-memory mock owner in `test/mock-feed.ts`). Preview fixtures: `bun first-party-apps/inbox/test/fixtures.ts --write`. The protocol types are in `src/feed.ts`.

## Contributions

| Contribution | Export | What it does |
| --- | --- | --- |
| sidebar section `inbox` | `renderInbox` | the main surface, in the selected variant |
| status item `badge` | `renderStatus` | tray glyph and the owner's unseen count (warning tone while something needs a response); reads `feed.counts` once, then the counts in each `feed.changed`; a click opens the most urgent unseen item; the menu lists the top 8 |
| pane kind `pane` | `renderPane` | the same surface in wide layouts (the platform does not mount pane kinds yet; the preview harness renders it) |
| commands | `openInbox`, `markAllSeen`, `nextItem`, `previousItem`, `openItem {id?}`, `markDone {id?}`, `snooze {id?, minutes?}`, `list {source?, needsResponse?, unseen?, includeSnoozed?, limit?}`, `refresh`, `cycleVariant` | palette entries; with `mcp:expose` each is an MCP tool. `id` defaults to the selected item, so the commands double as keyboard triage. There is no `respond` command |

## Scopes

| Scope | Why |
| --- | --- |
| `feed:read` | `feed.list`, `feed.get`, `feed.counts`, `feed.changed` |
| `feed:write` | `feed.mark`, `feed.snooze`, `feed.respond` |
| `actions:run` | run an item's open target or custom action (show the agent's tab, open a pull request, show the browser tab for a sign-in) |
| `mcp:expose` (optional) | agents can list items and mark them done or snoozed; they cannot answer requests through these tools |

`feed:read` and `feed:write` are not in the generated scope table yet (the validator warns).

## Variants (dogfood; `variant` setting or "Next Inbox Variant")

| Variant | Design |
| --- | --- |
| `grouped` (default) | dense native rows under the owner's groups (source, workspace or thread); a click opens; respond, done and snooze in the row menu; one filter pull-down |
| `focus` | icon chips (source, needs a response, unseen, mark all seen); a flat list where a click selects; a detail area with the body, the response form and Open / Done / Snooze / More. Side by side in a pane |
| `card` | one item at a time with "2 of 9", the response form, and Open / Done / Snooze / Skip |

Response forms follow the item's response schema: `choice` shows one button per option, `approve` shows Approve and Deny, `confirm` shows Confirm and Cancel, `text` shows an answer field, `external` (sign-in, passkey) shows "Continue in Browser", which runs the item's open target (show the agent's browser tab next to this one) and does not answer; the agent resumes when the owner sees the sign-in finish.

Recommendation: `grouped` for the sidebar, because it reads as native sidebar rows and opens in one click. Strongest objection: requests are answered from a right-click menu there (and `text` requests cannot be answered at all without opening the detail of another variant), so a feed full of requests is slower to clear than in `focus` or `card`.

## Requirements for the feed

What this view needs from the feed owner (lane 9). Names are proposals.

Item fields: `id` (`feed_…`), `kind` (`notify`, `request`, `watch`, `cancel`), `requestKind` (`question`, `choice`, `approve`, `confirm`, `sign-in`, `passkey`, `review`, `input`, `file`, `handoff`), `title`, `body`, `urgency` (`low`, `normal`, `high`, `critical`), `needsResponse`, `source {kind: agent|app|run|integration|user, id, name}`, `subject {machine?, workspace?, workspaceName?, tab?, terminal?, browser?, agent?, url?}` with names resolved by the owner, `thread`, `status` (`open`, `snoozed`, `done`, `canceled`, `expired`), `snoozedUntil`, `seenAt`, `createdAt`, `updatedAt`, `revision`, `expiresAt`, `response` (schema: `choice {options[{value, label, destructive?}]}`, `approve`, `confirm`, `text {placeholder?}`, `external`), `actions [{id, title, kind: open|respond|done|snooze|custom, value?, target?}]`, `open {action, args}`. `cancel` items never reach a list: the owner applies them to the request they cancel.

Ops:
- `feed.list {filter: {status?, kinds?, sources?, workspace?, needsResponse?, unseen?, query?}, groupBy?: source|workspace|thread, cursor?, limit?}` returns `{items, groups?: [{key, label, sourceKind?, itemIds}], cursor, revision, counts}` in the owner's order (needs a response, then urgency, then newest). `unseen` is an addition to the filter.
- `feed.get {item}`, `feed.counts` returns `{unseen, open, needsResponse, urgent, snoozed}`.
- `feed.mark {items[] | filter, state: seen|done|open}` returns `{revision, changed}`. The filter form makes "mark all as seen" one call.
- `feed.snooze {item, until}`: the owner fires the wake-up and the item comes back unseen. No client timer.
- `feed.respond {item, value}`: value shapes `{choice}`, `{approved}`, `{confirmed}`, `{text}`.
- Event `feed.changed {revision, changed[], counts}` for every change, including wake-ups, responses from other devices and expiry.

Grouping, order and counts: computed by the owner so every client (Mac, iPhone, web, TUI) shows the same groups, order and badge. Group labels need localization for well-known keys (the view localizes `sourceKind` groups).

Open targets: action ids from the action registry. The prototype needs two registry actions that do not exist yet: `tab.show {tab}` (show an agent's tab) and `browser.duplicateRight {browser}` (show the agent's browser tab duplicated to the right for a sign-in or passkey).

Badges: the status item shows `counts.unseen`, warning tone when `counts.needsResponse > 0`. A section header badge and an app-level Dock or menu bar badge need `app.badge.set` (below).

Permissions: `feed:read` to list and count, `feed:write` to mark, snooze and respond. `feed.respond` needs origin `user` (the client attests the gesture; the app calls it synchronously in the tap or menu handler) and is never an MCP tool for agents other than the item's addressee. An agent posting a request cannot answer it. Done, snooze and seen are user state and may be MCP tools.

## Proposed operations outside the feed

| Name | Params | Result | Owner | Risk | Scope | Why |
| --- | --- | --- | --- | --- | --- | --- |
| `app.badge.set` | `{contribution?, count \| null, tone?}` | `{}` | app supervisor; clients render it | mutate-own | none | section header badge, and an app-level badge for the Dock or menu bar |
| `app.pane.open` | `{contribution, placement?}` | `{tab_id}` | workspace store | mutate-own (moves focus only in a user turn) | `workspace:write` | "Open Inbox" needs to open the pane kind as a tab |
| `app.settings.set` | `{key, value}` | `{}` | config layer | mutate-own | none | "Next Inbox Variant" cannot write the `variant` setting; it stores an override in app storage instead |

## Platform gaps

1. User-invoked commands (palette, keybinding) run with origin `script`, so "Next Inbox Item" and "Open Selected Inbox Item" cannot move focus, and a command could not answer a request even for the user.
2. A tap's user turn across `await` is undefined; the app runs the open target and `feed.respond` synchronously in the handler.
3. No section header badge or accessories; the unseen count renders inside the section's toolbar.
4. No keyboard events in scenes and no default keybindings in the manifest.
5. No app lifecycle hook (`onCleanup`/unmount) and no way to share one subscription across mounts: each mounted list reads on its own.
6. No API for an app to know its granted scopes.
7. Menu items have no checked state and the typed API cannot set a menu item symbol, so the filter menu shows the current choice as disabled.
8. Stacks have no `alignment` prop; wide layouts end each column in a `Spacer`.
9. No multi-line text input for longer answers.
10. No locale in init or mount context and no app i18n API; `t()` reads `Intl` when the engine has it.
11. `x-cmux-devOnly` on a settings property is not honored yet.
12. No per-command MCP exposure flag.
13. Relative ages update only when data changes; there is no coarse, visibility-paused clock signal.
14. The typings omit `CmuxError`'s constructor and `untrack`, both present at runtime.
