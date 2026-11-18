# Agent UI surfaces: MCP Apps and A2UI drawn by the chat pane (prototype)

Status: design plus a disposable prototype, behind `labs.agentUiSurfaces` (off by default).
Gap: cmuxterm-hq `plans/quit-gaps.md` A18 ("no MCP Apps host side, no chart fence, progress fence").
Trust rules: cmuxterm-hq `docs/probes/6236-31/README.md` (data only, strict validation, unknown
input degrades to inert text, a privileged action needs host authorization, no model-supplied
command becomes a bridge call).

Leo, 2026-11-18: "https://developers.googleblog.com/a2ui-10-build-delightful-fast-reliable-agentic-experiences/ this was here too recently".

## What it does

An agent (or an MCP server the agent uses) describes a view; cmux draws it with its own
registered components in the chat pane, on Mac and iPhone:

- **A2UI 1.0** messages (`createSurface`, `updateComponents`, `updateDataModel`, `deleteSurface`,
  `callRendererFunction`), from the `cmux` MCP server's `ui_surface` tool (like `render`), or from
  an MCP tool result carrying a resource of mimeType `application/a2ui+json`.
- **MCP Apps**: a tool whose definition carries `_meta.ui.resourceUri` (`ui://...`). If the resource
  is `application/a2ui+json`, it is drawn with our components. If it is `text/html;profile=mcp-app`,
  it runs in the existing sandboxed render frame (`AgentPaneRenderFrame`, `sandbox allow-scripts`, no
  same-origin) with the CSP built from `_meta.ui.csp` (default `connect-src 'none'`), and every
  JSON-RPC message from the view goes through the Rust mediator.

"Native" here means drawn by cmux's own registered components, never agent-supplied markup. On Mac
those components are the chat pane's own React (`.github/language-boundaries.toml`: "chat ui lives in
react"; macOS forbids new SwiftUI, `plans/cmux-next/no-swiftui-DESIGN.md`); on iPhone they are
SwiftUI in `CmuxMobileAgentChat`. Both draw the same normalized model, which only Rust produces.

## Layers

| Layer | Where | Language |
|---|---|---|
| Parse, validate, bind, cap, mediate | `cmux-tui/crates/cmux-ui-surfaces` (pure, no I/O) | Rust |
| Source: `ui_surface` tool, tool-row attachment, MCP Apps resource fetch, action confirm RPC | `cmux-tui` (`cli/mcp`), `acpmux-book`, `acpmux` | Rust |
| Mac drawing | `webviews/src/agent-session/acpmux/uiSurface/` | React (chat-ui area) |
| iPhone drawing | `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileAgentChat/UISurface/` | SwiftUI |
| Flag | `schemas/settings/source/labs.json` `labs.agentUiSurfaces` | JSON source, generated Swift |

With the flag off, Rust never builds a surface and never fetches a `ui://` resource; the tool row
draws as today.

## Normalized surface model (`cmux.ui-surface/1`)

Rust emits this; the renderers draw only this. Unknown or invalid input becomes a `fallback` node
with inert text. Strings are plain text (no HTML, no Markdown links that act).

```jsonc
{
  "schema": "cmux.ui-surface/1",
  "surfaceId": "s1",
  "source": { "kind": "a2ui" | "mcp-app", "server": "quickstart", "tool": "get-time",
              "resourceUri": "ui://get-time/mcp-app.html", "catalogId": "..." },
  "status": "streaming" | "ready" | "error",
  "error": "optional plain text",
  "title": "optional",
  "root": Node,
  "frame": null | { "html": "...", "csp": "default-src 'none'; ...", "height": 320 },
  "pending": null | Pending      // an action waiting for the person's confirmation
}
```

Nodes (every node has `id`, optional `a11y: {label, description, live: "polite"|"assertive", hidden}`):

| type | fields |
|---|---|
| `text` | `text`, `style`: `body` `heading` `caption` `code` |
| `stack` | `axis`: `v` `h`, `children` |
| `card` | `children` |
| `list` | `children` |
| `divider` | |
| `icon` | `name` (from a fixed set; unknown names draw nothing) |
| `image` | `alt` (prototype draws the alt text in a frame; no network fetch) |
| `button` | `label`, `action`, `variant`: `primary` `secondary` `danger` |
| `field` | `label`, `input`: `text` `checkbox` `choice` `slider` `date`, `value`, `options` [{`value`,`label`}], `multi`, `min`, `max`, `bind` (data-model path, host-held), `secure` (masked text, A2UI `obscured`) |
| `approval` | `title`, `detail`, `risk`: `low` `medium` `high`, `facts` [{`label`,`value`}], `approve` action, `deny` action |
| `review` | `title`, `prompt`, `options` [{`id`,`label`,`detail`}], `multi`, `submit` action, `bind` (where the selected ids go in `values`), `selected` [id] |
| `table` | `columns` [{`key`,`label`,`align`}], `rows` [[string]], `truncated` (rows capped at 200) |
| `chart` | `kind`: `bar` `line` `pie`, `series` [{`name`, `points` [{`x`,`y`}]}], `yLabel` |
| `progress` | `label`, `value`, `max` (both absent = indeterminate), `state`: `running` `done` `failed` |
| `fallback` | `text` (what could not be drawn, e.g. "AirportPicker (travel catalog)") |

`action` on a node is `{ "id": "a3", "name": "submit", "privileged": true }`. The renderer never
builds a payload: it sends `uiSurfaceAction {surfaceId, actionId, values}` where `values` are the
current field values it holds, keyed by `bind`. Rust answers with a `Pending`:

```jsonc
{ "requestId": "r7", "actionId": "a3", "summary": "Send \"submit\" to the agent with: name = Ada, seat = window",
  "sends": [ { "label": "name", "value": "Ada" } ],
  "target": "agent" | "tool:get-time" | "link:https://..." }
```

Additions to the contract made while building the prototype: `source.claimed` (bool, omitted when
false), `field.secure`, `review.bind` and `review.selected`. Node ids are
the A2UI component ids; a node a `children` template repeats gets `#<index>` (nested `#i.j`), and an
action's id is its button's node id (`<id>.approve`, `<id>.deny`, `<id>.submit` on cards). A text
component whose string starts with Markdown `#`..`######` becomes `style: heading` without the marks.

### The cmux catalog (`https://cmux.com/a2ui/catalog/v1`)

The basic catalog's components plus these (props are A2UI dynamic values unless noted):

| component | props | node |
|---|---|---|
| `ApprovalCard` | `title`, `detail`, `risk` (`low` `medium` `high`, default `medium`), `facts` [{`label`,`value`}], `approveAction`, `denyAction` (A2UI actions) | `approval` |
| `ReviewCard` | `title`, `prompt`, `options` [{`id`,`label`,`detail`}], `multi` (bool), `value` (`{"@path"}` holding the selected ids; default `/@review/<id>`), `submitAction` (its context gains `selected`) | `review` |
| `Table` | `columns` [string or {`key`,`label`,`align`: `start` `center` `end`}], `rows` ([[cell]] or [{key: cell}], or `{"@path"}`) | `table` |
| `Chart` | `kind` (`bar` `line` `pie`), `series` [{`name`, `points` [{`x`, `y` number}]}], `yLabel` | `chart` |
| `Progress` | `label`, `value`, `max`, `state` (`running` `done` `failed`) | `progress` |

The travel catalog draws its basic components; `AirportPicker`, `DateRangePicker`, `Flights`,
`Trip`, `ItineraryDay`, `StatTile` and its other widgets are `fallback` nodes naming the widget. A
component with an `@catalogId` cmux does not know, and the A2UI MCP catalog's `McpApp`, are fallbacks;
a surface whose `catalogId` is unknown is `status: error`. An omitted `catalogId` means basic (the
spec calls it an error; the `ui_surface` tool's agents often omit it).

### Crate `cmux-tui/crates/cmux-ui-surfaces`

Pure, no I/O. `a2ui` parses messages (array, `{messages}`, JSONL with a partial last line while
streaming); `store::SurfaceStore` applies them, holds each surface's data model, builds the
normalized model (`model`), and mediates actions: `request_action(surface, action, values) ->
Pending`, `values_changed`, `confirm(request, values?, timestamp) -> Outbound`, `cancel`, and
`bridge(surface, json-rpc)` for an MCP App view. `functions` evaluates `@path`, `@call` and
`formatString` against the allowlist; `mcp_apps` reads `_meta.ui`, `resources/read` contents and
builds the CSP; `coalesce::Coalescer` is the 16 ms per-surface emit gate. Fixtures for the
renderers: `tests/golden/*.json` (one per quickstart sample, plus `cmux-catalog-cards`,
`cmux-pending` and `mcp-app-frame`), each `{sample, surfaces: [Surface], errors, replies}`;
`UPDATE_GOLDEN=1 cargo test -p cmux-ui-surfaces --test quickstart_golden` rewrites them.

### Wiring

- The daemon's tap writes the surface into the logged tool update as `_meta.acpmux.uiSurface`;
  the translator puts it on the tool row as body field `uiSurface` (an object, replaced whole).
- An MCP App's tools and `ui://` resources are fetched at the call's first update (on the hub's
  scope). A view that comes after the call's result is logged as a `ui_surface` mux record
  `{toolCallId, kind, status, tool, title, rawInput, content, surface}`: the translator puts it on
  the open row, or patches the settled one (a patch replaces the whole body, so the record sends
  the row's other parts again). So a tool's first call draws. The translator holds the 32 newest
  settled tool rows for this, outside its checkpoint; a call with terminal output or a part over
  256 KB gets no late surface.
- RPC: `_acpmux/ui_surface_action {sessionId, surfaceId, actionId, values}` -> Pending;
  `_acpmux/ui_surface_confirm {sessionId, surfaceId, requestId, values?}` -> `{sent: agent|tool|link,
  reply?, openUrl?}` (person or authenticated remote only); `_acpmux/ui_surface_cancel {sessionId,
  surfaceId, requestId}` -> `{cancelled}`; `_acpmux/ui_surface_bridge {sessionId, surfaceId, message}`
  -> `{reply?, notify?[], height?, blocked?, pending?, draft?}`.

The card shows this host-written summary with Confirm and Cancel. Only `uiSurfaceConfirm
{surfaceId, requestId}` sends anything (the A2UI `action` message back to the agent as a user turn,
or the MCP `tools/call`). Cancel or a changed value drops the request. Approval cards' approve and
deny are actions like any other: one click shows the confirm strip, a second confirms. Keyboard:
Return confirms, Escape cancels.

## Trust and permission mediation (per 6236-31)

- **Data only.** A2UI content can declare components, values and named actions. It cannot carry
  HTML, scripts, URLs that load, credentials or command strings. `@call` functions run only from a
  fixed allowlist (`formatString`, `formatNumber`, `formatCurrency`, `pluralize`, `required`,
  `email`, `length`, `regex` without backtracking blowup, and the pure checks `numeric`, `and`,
  `or`, `not`, `@index`; any other function, `formatDate` included, is empty text); an agent's
  `callRendererFunction` gets the same allowlist; `openUrl` becomes a link action that
  needs confirmation and only allows `https`.
- **Caps.** 512 components, depth 32, 200 table rows, 1,000 chart points, 4 KB per string, 256 KB
  per surface; over a cap the surface shows what fit and a `fallback` saying what was cut.
- **Catalogs.** Supported: the A2UI basic catalog v1, the cmux catalog
  (`https://cmux.com/a2ui/catalog/v1`: `ApprovalCard`, `ReviewCard`, `Table`, `Chart`, `Progress`),
  and, for the quickstart, the travel catalog treated as basic plus fallbacks for its own widgets.
  Capabilities sent to agents: `a2uiRendererCapabilities {"1.0": {supportedCatalogIds: [...]}}`.
- **Binding stays in the host.** The data model lives in Rust. Field edits stay local; the agent sees
  values only in a confirmed action's `sends`, which the person has read. `sendDataModel` is honored
  only through the same confirm strip (the summary lists every path sent).
- **MCP Apps bridge.** View-to-host methods, classified by Rust:

| method | decision |
|---|---|
| `ui/initialize`, `ui/notifications/initialized`, `ui/notifications/size-changed` | allowed (size clamped 40-1200 px) |
| `tools/call` | refused unless the tool's `visibility` includes `"app"`; otherwise a Pending with the tool name and arguments, sent only on Confirm |
| `ui/message` | fills the composer; the person presses Send (6236-31 "draft prompt") |
| `ui/open-link` | Pending, `https` only |
| `ui/update-model-context` | refused with its reason: ACP cannot add context to the next turn without starting one, so a Confirm would send nothing; the view drafts with `ui/message` instead |
| `resources/read` | allowed for `ui://` on the same server only |
| `sampling/createMessage`, `ui/download-file`, anything else | refused, logged, the card says "blocked" |

  The host sends nothing to the view before `initialized`. The frame gets the tool input and result
  (`tool-input`, `tool-result`), which the agent already saw.
- **Origin.** The `source` line on every card names the server and tool; a server not connected by
  the person shows "claimed".

## Streaming and frames

Rust coalesces updates per surface to one row update per animation frame (16 ms) and emits whole
normalized nodes, not diffs, for surfaces under 64 KB. The Mac page keeps nodes keyed by `id`, so a
streamed `updateComponents` re-renders only changed nodes; the card reserves its height from the
first `createSurface` (`minHeight` grows, never shrinks while streaming), so the transcript below does
not jump. Measurement: `webviews/bench/ui-surface-stream-frames.bench.ts` streams a 40-update
surface into a 1,500-row transcript and reports frames over 16 ms against the same transcript
without it; on a fleet Mac, golden.py's `ui_surface_stream` scenario
(`scripts/ci/frame-pacing/ui_surface_stream.py`, `debug.agent_pane` `stream` with `surface`) streams the same
fixture (`webviews/src/agent-session/acpmux/uiSurfaceStreamFixture.ts`) in the live pane, with and without the
card, and reports its frames (report only).

## Not in the prototype

Persisted surfaces across restart, `Video`/`AudioPlayer`/`Modal` (fallbacks), iPhone MCP App HTML
frames (fallback "Open on Mac"), stdio MCP servers for `ui://` fetch (HTTP only), A2A transport.
