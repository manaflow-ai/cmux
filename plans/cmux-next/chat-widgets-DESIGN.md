# Chat widgets and a customizable chat UI

Status: slice 1 in progress (2026-11-08). Owner: a1061.
Asks: Lawrence, Nov 7: "some people want to customize stuff in imessage ui itself as
well, so the JS thing can be helpful for making widgets that ai can send"; "js widgets
should still be in swift tho right, and need to consider pagination and state";
"people want to customize the chat ui itself, look at get-bb/bb and herdrdev/herdr-app".

## 1. What we build

The JS app runtime that already draws custom sidebar sections (`cmux.section/1`,
`~/.config/cmux/customize`, `samples/apps`, `skills/cmux-customization`) also powers
the Home chat:

1. **Widget messages.** An agent or the Chief sends a message part
   `{type: "widget", app, widget, props, fallback, url?}`. A Mac with that app
   installed mounts the app's `cmux.chat.widget/1` export with the props and draws the
   scene it returns **with native Swift drawing, never a webview**: the same scene kit
   (Row, Text, Button, Badge, EmptyState, stacks) as the custom sidebars, drawn in the
   transcript's own bubble style. Every other client draws the `fallback` text.
2. **Chat UI contributions.** Users change bits of the chat UI itself (composer
   buttons, bubble extras, theme tokens) with new contribution points of the same app
   model (section 5). No CSS, no DOM.

JS supplies data and logic only. Swift owns layout, drawing, motion, hit testing,
accessibility and scrolling.

## 2. What we learned from bb and herdr-app

bb (get-bb/bb, TypeScript web + Electron) has a thread timeline with plugin renderers.
herdr-app (herdrdev/herdr-app, Rust + GPUI, QuickJS mods) has no chat but the best
layout and config story. Sources: bb `docs/provider-plugin-api.md`,
`docs/timeline-pagination.md`, `plugins/bb-guide/skills/bb-plugin-authoring/references/frontend-renderer-slots.md`,
`docs/forkable-plugins.md`; herdr `defaults/AGENTS.md`, `defaults/herdr.d.ts`,
`defaults/layouts/main.json`, `docs/security.md`.

### What we take

| From | Idea | In cmux |
|---|---|---|
| bb | Typed custom items: `kind` + schema-checked `payload` + a required declarative `presentation`; "every client renders everything without plugin code" | Widget part carries a required `fallback` (and optional `url`); the owner checks the part; a client without the app draws the fallback |
| bb | Bad payloads are stored as `unhandled`, never dropped, never stored unchecked | The owner refuses a malformed widget part at send (the sender gets the error); readers keep unknown parts as `Unknown` JSON (already true) |
| bb | Renderer gets an `Original` delegate | A widget export may return `null`: the host draws the fallback bubble |
| bb | Widget-local state keyed `messageId#kind#index`, so it outlives unmounted rows | Mount key and storage key `widget:<message>#<part>`; the mount lives while the message is in the projection window, not only on screen; `cmux.storage` keeps state across relaunch |
| bb | Live updates as deltas against a tag; one owner of the scroll anchor | The mount streams scene ops (existing `apps-scene` stream); a changed scene bumps the custom part's version, the transcript re-measures and animates height with its own anchor (no new scroll code) |
| bb | Exclusive slots with an automatic default (composer, thread list) and additive slots (message actions, composer menu items) | `cmux.chat.composer.button/1` and `cmux.chat.message.action/1` are additive; no exclusive replacement of the composer or transcript (section 5) |
| bb | Themes from two anchors (`--canvas`, `--ink`) plus an accent, light/dark sections | Chat theme tokens: canvas, ink, accent, incoming/outgoing bubble; the rest derives (section 5.3) |
| bb + herdr | Plugins ship skills / an always-current `AGENTS.md` + `.d.ts` | `skills/cmux-customization` and `cmux-app.d.ts` gain the widget interface; agents learn it from there |
| herdr | Bad config keeps the last good version and writes an error next to it; a reset that cannot be rebound | A widget export that throws draws the fallback plus the error in the app's log; a bad customize reload keeps the last good mount (a1060's reload work) |
| herdr | Shipped layouts and mods are read-only; copy to customize | Sample widgets live in `samples/apps`; users copy them into `~/.config/cmux/customize` |
| herdr | Scripts describe elements; native code draws them (no DOM) | Same as our scene kit; confirms the Swift-only rule |
| herdr | Virtual lists for long data | Pagination inside a widget is the app's (page signal + "Show more" Button); the host caps a widget's height (section 4) |

### What we skip

| From | Idea | Why |
|---|---|---|
| bb | Full-trust same-origin plugin page code | Gives the whole app to plugin code; our apps run sandboxed with declared scopes |
| bb | Model-written HTML in a sandboxed iframe (`inline-vis`) | User rule: widgets are Swift, never a webview |
| bb | Arbitrary user CSS over the app shell | AppKit has no cascade; we expose tokens, not selectors |
| bb | Exclusive replacement of the composer or the transcript | The Home transcript is tuned native code (morphs, springs, glass); a replacement loses it. Additive slots only |
| bb | v3 cursors, content cuts, 4 MiB budgets for the timeline | Home already pages by message seq (`HomeTranscriptPager`) |
| herdr | Embedded second UI toolkit (QuickJS + GPUI builders) | We already have one kit; no second one |
| herdr | Mods with free `exec`/`fetch` | Capabilities stay declared scopes with consent |
| herdr | Telemetry on by default | Unrelated, costs trust |

## 3. The widget part (wire)

```json
{
  "type": "widget",
  "app": "cmux/pr-card",
  "widget": "cmux.chat.widget/1",
  "props": { "repo": "manaflow-ai/cmux", "number": 38629 },
  "fallback": "PR #38629: Model picker finds any model (open, checks passing)",
  "url": "https://github.com/manaflow-ai/cmux/pull/38629"
}
```

- `app`: the app id (`publisher/name`, as in `cmux-app.json`).
- `widget`: the interface the app implements, `cmux.chat.widget/1` in v1 (room for
  named widgets later: `cmux.chat.widget/1#name`).
- `props`: a JSON object, at most 16 KiB serialized. Data, never code.
- `fallback`: required, 1 to 2000 characters, plain text. What every client without
  the renderer shows (iPhone, a Mac without the app, notifications, search, Copy).
- `url`: optional `https` link. Builds from before this part show a part they do not
  know as its `url` (HomeWireMapping, ConversationPart); so the fallback on today's
  iPhone build is the link, and on new builds the fallback text.
- Only agents (the Chief or an agent participant) may send a widget part; the owner
  refuses it from a human, as for `question`.
- Live updates of an already sent widget do not edit the message: the widget is a
  live view of its props (a PR number), so new data comes from the app. A sender that
  wants to change the props edits the message (`message.edit`), which the owner
  already supports; the row re-mounts with the new props.

## 4. Rendering on the Mac

- The Home transcript's custom-row seam (`CustomPart`, `TranscriptCustomRowProvider`,
  `drawsRow`) draws the widget into its row bitmap. Home has no live-view host for
  custom rows, so there is no NSView per row: `HomeWidgetRowProvider` draws a value
  snapshot of the scene and hit-tests clicks. This keeps scrolling at the transcript's
  cost (one bitmap per row, drawn off main).
- `HomeWidgetHosting` (a protocol seam in MessagesLabHome) gives the provider a
  snapshot for `widget:<message>#<part>` and takes taps. The app target implements it
  with `AppsClient.mount(app, implementation: cmux.chat.widget/1, surface: "chatWidget",
  context: {props, widget: {key, message, part}})` and maps the mount's `AppScene` to
  a `HomeWidgetSnapshot` (rows, text, buttons, badges, empty states, dividers).
- A scene change publishes a new snapshot; the provider's part version changes and the
  transcript re-measures and animates (rows below move, the anchor stays).
- A tap on a row or button dispatches `tap` to that node (`AppMount.dispatch`), so
  `cmux.actions.run` goes through the app's granted `actions:run` scope: no consent, no
  action. A widget from an app that is not installed draws the fallback with an
  "Install" hint, never runs anything.
- Height: at most 420 pt wide (the bubble column) and 12 rows tall; more rows are the
  app's to page.
- Light and dark: the snapshot carries semantic tints (`accent`, `success`,
  `warning`, `danger`, `secondary`), resolved with the transcript palette.

### Pagination

Long lists page inside the card, owned by the app: the export keeps a `page` signal,
shows `pageSize` rows and a "Show more" Button (or Previous/Next). The host caps the
rows it draws (12) so a widget never becomes a wall. Paging changes the scene, which
re-measures the row like any other update.

### State

- Scroll: the mount lives as long as the message is in the projection window (the
  pager's loaded range), keyed by `widget:<message>#<part>`, so scrolling away and back
  keeps the page and any signal.
- Relaunch: the context's `widget.key` is the storage key; the app saves what must
  outlive the process with `cmux.storage.set(key, value)` (`storage:local` scope) and
  reads it on mount. The sample PR card keeps its page this way.
- Live updates: the mount is live; the app refreshes with `cmux.timer.every` (the
  sample: 60 s) or on a `cmux.events` subscription; each change re-renders the row.

## 5. Customizing the chat UI itself (later slices)

1. `cmux.chat.composer.button/1`: an app adds a button to the composer's plus menu
   (symbol, title, action). The action runs the export with the draft context
   `{conversation, draft_text}` and may return text to insert or a widget part to send.
2. `cmux.chat.message.action/1`: an item in a bubble's context menu (Copy as…, Open
   in…), with the part's plain text and its widget props as context.
3. Chat theme tokens in `cmux-next.json` `chat.theme` (`canvas`, `ink`, `accent`,
   `incomingBubble`, `outgoingBubble`, `light`/`dark` blocks), checked by the settings
   schema, applied live; everything else derives (contrast is checked by the existing
   palette tests).
4. Bubble extras (`cmux.chat.bubble.badge/1`): a small badge on bubbles that match a
   filter (author, text regex), drawn by the transcript.

Each is additive and declarative; none replaces the transcript or the composer.

## 6. Agents

- Chief: `send` takes `widget: {app, props, fallback, url?}`; the message is the text
  (if any) plus the widget part.
- Other agents and scripts: the daemon's `message.send` op accepts the widget part as
  is (any client of the conversation API).
- `skills/cmux-customization` documents writing a widget export and sending one.

## 7. Slice 1 (this landing)

- Owner (`cmux-conversation`): `Part::Widget`, checked (agent author, sizes, `https`
  url), plain text = fallback for search and notifications.
- Chief `send` gains `widget`.
- Interface `cmux.chat.widget/1` in the manifest crate and the Swift app model.
- Home core: `MessagePart.widget`, wire mapping, plain text.
- MessagesLabHome: `HomeWidgetRowProvider` and the `HomeWidgetHosting` seam.
- App: the AppsClient-backed host.
- Sample `samples/apps/pr-card`: a PR status card with checks paged 5 at a time,
  page kept in `cmux.storage`, refreshed every 60 s.
- Tests: owner validation, wire mapping, provider layout and hit test.

Later: hosted (cloud) owner support in `backend/packages/home-core`, iPhone native
drawing of the snapshot, composer buttons, message actions, chat theme tokens.
