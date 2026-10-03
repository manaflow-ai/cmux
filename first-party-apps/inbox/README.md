# Inbox (`cmux/inbox`)

A view on the cmux feed (`plans/cmux-next/feed.md`). The feed is one per-user list of notices and requests, owned by `FeedDO` with a local owner as fallback. Agents, apps, automations, servers and integrations post items; GitHub review requests and failing checks arrive as feed items posted by the integration side. This app does not call GitHub and keeps no item store.

The owner keeps items, lifecycle (open, answered, cancelled, expired), triage (read, seen, archived, snoozed), order, groups, counts and snooze wake-ups. The app lists with `feed.list`, then follows the owner's op events on the feed stream: each event is one committed op (`{seq, op, params, actor, at}`), and `src/events.ts` derives the listed page's change from it with the owner's rules (answer, cancel, read, seen, archive, snooze, expire). Events that bring items the page cannot know (post, adopt, unarchive, snooze wake-ups) cause one new list per burst; any count-changing event re-reads `feed.counts`. App storage holds only view preferences (filters, grouping).

Build: `bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/inbox`. Validate: `bun cmux-tui/crates/cmux-app-host/tools/validate-manifest.ts first-party-apps/inbox`. Test: `bun test first-party-apps/inbox/test` (FakeHost with the mock owner in `test/mock-feed.ts`, which emits op events). Preview fixtures: `bun first-party-apps/inbox/test/fixtures.ts --write`. `cmux-app.v2.json` is the manifest v2 sketch.

## Contributions

| Contribution | Export | What it does |
| --- | --- | --- |
| sidebar section `inbox` | `renderInbox` | the main surface, in the selected variant |
| status item `badge` | `renderStatus` | tray glyph and badge: open requests in the warning tone while any wait, else unread items; the menu lists the top 8 of the owner's urgent order; a click opens the first |
| pane kind `pane` | `renderPane` | the same surface in wide layouts (the platform does not mount pane kinds yet; the preview harness renders it) |
| commands | `openInbox`, `markAllRead`, `nextItem`, `previousItem`, `openItem {id?}`, `markDone {id?}`, `snooze {id?, minutes?}`, `cycleVariant` | palette entries; `id` (`fi_…`) defaults to the selected item. No MCP tools and no answer command |

Agents use the feed's own surfaces (`feed_request`, `feed_notify`, `feed_list`, `feed_get`, `feed_cancel` MCP tools; `cmux feed …`), which show an agent only its own items. The inbox exposes no MCP tools: through the app an agent would read every item and triage for the user, which the feed refuses to agents (`mcp: never` on triage and answers).

## Opening, answering and triage

- Open: every item opens through the feed's own action `feed.openItem {item}` (actions registry), called synchronously in the tap so it carries the tap's gesture token. The action reads the item and runs its `open` target (`tab.focus`, `workspace.focus`, `url.open`, `browser.open`, `task.open`, `acp.session.open`, `app.open`). Sign-in and passkey requests also go through `feed.openItem`, which runs the whole handover (agent tab paused, the user's copy opened to the right, the Mac's browser answers). The app never calls `browser.duplicateRight` or any open target itself.
- Answer: only the user answers. `feed.answer {item, answer}` presents the gesture token of the tap that chose the answer (`{gesture}` option, origin `user`); without a token (a command, an agent, a script) the app sends nothing. Forms follow the kind registry: `choice` (one tap for a single single-select question, else toggles and Send, free text when `allow_other`), `approve` (Allow, Allow for Session and Always Allow when offered, Deny), `confirm`, `question` (suggestions and a field), `review` (Approve or Request Changes with an optional comment), `handoff` (Take Over, Let the Agent Resume), `input` and custom kinds with a flat schema (fields and Send), poster buttons that carry an `answer`. `sign-in` and `passkey` show Continue in Browser only. `file` cannot be answered here (gap 4).
- Decline: `feed.cancel {item, reason: "declined"}` with the tap's gesture. The waiting agent gets "declined".
- Triage: `feed.read`, `feed.archive` (Done), `feed.unarchive` (Move Back to Inbox), `feed.snooze`. An open request is never offered Done or Snooze (the owner refuses both); it offers its answers and Decline. "Mark All as Done" archives by filter, which the owner applies to everything but open requests.

## Scopes

| Scope | Why |
| --- | --- |
| `feed:read` | `feed.list`, `feed.get`, `feed.counts`, the feed stream |
| `feed:write` | `feed.read`, `feed.archive`, `feed.unarchive`, `feed.snooze`; today also `feed.answer` and `feed.cancel` |
| `feed:answer` (v2 sketch only) | `feed.answer` and the user's decline. The v1 manifest schema rejects the verb `answer` in a scope, and the generated scope table maps `feed.answer` to `feed:write` (gap 1) |
| `actions:run` | `feed.openItem` |
| `workspace:read` (optional) | workspace names on rows and on workspace group headers (the owner's group label is the workspace id) |

## Variants (dogfood; `variant` setting or "Next Inbox Variant")

| Variant | Design |
| --- | --- |
| `grouped` (default) | dense native rows under the owner's groups (sender, workspace or thread); a click opens; answers, Decline, Done and Snooze in the row menu; one filter pull-down |
| `focus` | icon chips (sender kind, needs an answer, unread, mark all read); a flat list where a click selects and reads; a detail area with the answer form and Open / Decline or Done / Snooze. Side by side in a pane |
| `card` | one item at a time with "3 of 10", the answer form, and the same actions plus Skip |

Recommendation: `grouped` for the sidebar: it reads as native sidebar rows and opens in one click, and the menu covers the one-tap answers (approve, confirm, single choice). Strongest objection: requests that need typing (question, input, review comments, multi-question choice) cannot be answered from a row menu at all, so a feed full of those is slower to clear than in `focus` or `card`.

## Requirements for the feed: what is still missing

The feed now provides what this view asked for earlier: `fi_…` ids, `type` plus `kind` with a kind registry and answer schemas, `priority`, poster and context refs, threads and dedupe, owner order, grouping and counts, separate triage verbs (`feed.read`, `feed.seen`, `feed.archive`, `feed.unarchive`, `feed.snooze`) with item, `all` and filter forms, owner snooze wake-ups, `feed.answer` (origin user, `mcp: never`), the user's Decline, the rule that open requests cannot be archived or snoozed, op events instead of a "changed" summary, and open targets limited to open-style actions with the existing `tab.focus`. Still missing, most important first:

1. `feed:answer` scope. The scope pattern has no `answer` verb and `generated/scopes.json` maps `feed.answer` and `feed.cancel` to `feed:write`, so a third-party app with `feed:write` could send answers when it holds a gesture token. Owner: app platform (scope table) + feed lead.
2. `feed.openItem` action. The client action that reads an item and runs its open target, and the sign-in and passkey handover, is designed (feed.md 10.2, 12) but not in the action registry. Until then Open shows "cannot open feed items yet". Owner: feed lead (F3, F7) with the browser lead.
3. The feed stream for apps. The app host has no binding of the user's feed stream (`feed:<user>` op events) to an app subscription; the app subscribes to `feed`. Owner: app platform.
4. A list revision. FeedDO answers reads with `revision: ""`, so a page cannot tell which stream `seq` it reflects; an event that raced the list read is applied twice (harmless for these idempotent rules) or missed until the next relist. Wanted: `feed.list` returns the `seq` it reflects. Owner: FeedDO.
5. Snoozed list and count. `feed.list` hides snoozed items and has no `snoozed: true` filter, and `feed.counts` has no snoozed figure, so the app cannot show "3 snoozed" or let the user unsnooze. Wanted: `feed.list {snoozed: true}`, `counts.snoozed`, `feed.unsnooze {items}`.
6. Badge figure. `feed.counts.unread` includes unread open requests, and nothing gives "unread notices", so the badge cannot follow the user's `feed.badge = requestsAndUnread` rule; it shows open requests, else unread items. Wanted: `counts.unread_notices` or `counts.badge` computed by the owner from the user's setting.
7. `poster_kind` takes one kind, so "Agents" cannot include `harness` items and an "Other" filter (apps, servers, VMs) is impossible. Wanted: `poster_kind: [kinds]`.
8. Workspace group labels are workspace ids. The app resolves names with `workspace:read`; other clients without that scope show ids. Wanted: the owner (or the client mirror) resolves context names.
9. File answers. A `file` request needs a user-picked file uploaded as an attachment (`fs.pick` handle, then an attachment upload op); there is no such path for apps.
10. `feed.read` has no "unread" inverse (`feed.unread`) for "Mark as Unread".

## Proposed operations outside the feed

| Name | Params | Result | Owner | Risk | Scope | Why |
| --- | --- | --- | --- | --- | --- | --- |
| `feed.openItem` (action) | `{item}` | `{}` | the client that holds the context (feed action, F3/F7) | mutate-own, focuses, gesture required | `actions:run` | one open path for every client and kind; the handover for sign-in and passkey |
| `app.pane.open` | `{contribution, placement?}` | `{tab_id}` | workspace store | mutate-own (focuses, gesture required) | `workspace:write` | "Open Inbox" needs to open the pane kind as a tab |
| `app.badge.set` | `{contribution?, count \| null, tone?}` | `{}` | app supervisor; clients render it | mutate-own | none | section header badge, and an app-level badge for the Dock or menu bar |

## Platform gaps

1. Palette commands carry no gesture token, so "Next Inbox Item" and "Open Selected Inbox Item" call `feed.openItem` as origin `script` and cannot move focus. Wanted: the host passes a gesture with a user-invoked command.
2. No section header badge or accessories; the count renders inside the section's toolbar.
3. No keyboard events in scenes and no default keybindings in the manifest.
4. Menu items have no checked state and the typed API cannot set a menu item symbol, so the filter menu shows the current choice as disabled.
5. Stacks have no `alignment` prop; wide layouts end each column in a `Spacer`.
6. No multi-line text input for longer answers and review comments.
7. Today's Swift prototype engine passes neither `locale` nor `strings` at init, so `cmux.t` returns the app's bundled fallback; the app's `t()` picks the bundled table by `cmux.app.locale`.
8. `x-cmux-devOnly` on a settings property is not honored by today's Settings UI.
9. Relative ages update only when data changes; there is no coarse, visibility-paused clock signal.
10. The typings omit `CmuxError`'s constructor, which the commands use to return error codes.
11. The preview engine's bundled scope table predates the feed ops; preview fixtures name their scopes.
