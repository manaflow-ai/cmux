# cmux extension SDK

Change cmux to fit how you work: add a sidebar section, open your own pane, react when a
workspace, an agent or a chat changes, and share it as an extension. cmux reloads it on every
save while you work on it.

One SDK, two languages, one version (1.0.0), made from the runtime's own tables (no copies):

| | TypeScript (`typescript/`, package `cmux-extension-sdk`) | Rust (this crate, `cmux-extension-sdk`) |
| --- | --- | --- |
| For | the extension's own code, which cmux runs in its sandbox | tools, tests and servers around an extension |
| Gives | places (`section`, `pane`, `newTab`, `widget`, `chatWidget`, `command`), widget layout helpers (`WidgetFrame`, `BigNumber`, `RowList`, ...), live lists (`workspaces`, `agents`, `chats`), events (`on`, `onChange`), the scene DSL (`VStack`, `Row`, ...), `cmux` (every op, typed) | versions, the event and signal tables with their scopes, `Manifest` (a typed `cmux-app.json` builder), `validate` and `check_package` (cmux's own validator) |

The working example is [`examples/extensions/activity`](../../../examples/extensions/activity):
a sidebar section and a pane, built only against this SDK. A pane can also be your own HTML
page (`render: web`): [`examples/extensions/web-pane`](../../../examples/extensions/web-pane)
calls cmux through `cmux-extension-sdk/web`, with the same scopes as a script.

## Make one

```sh
mkdir my-ext && cd my-ext
npm install cmux-extension-sdk        # or: bun add cmux-extension-sdk
```

Until the package is on npm, point at a cmux checkout:
`bun add file:<cmux>/cmux-tui/crates/cmux-extension-sdk/typescript`. `cmux ext dev` needs neither:
with no copy in the folder, it builds against the SDK built into the CLI.

`cmux-app.json`: what the extension is, the places it fills, and the scopes it asks for.

```json
{
  "$schema": "<cmux>/cmux-tui/crates/cmux-app-host/schema/v2/cmux-app.schema.json",
  "manifestVersion": 2,
  "id": "local/my-ext",
  "name": { "en": "My extension" },
  "version": "0.1.0",
  "description": { "en": "My workspaces, live." },
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "dist/main.js" },
  "implements": {
    "cmux.section/1": { "export": "renderSection", "title": { "en": "Mine" }, "symbol": "sparkles" }
  },
  "scopes": { "workspace:read": "List your workspaces." }
}
```

`src/main.ts`: export the function the manifest names.

```ts
import { ForEach, Row, VStack, section, workspaces } from "cmux-extension-sdk"

export const renderSection = section(() => {
  const spaces = workspaces()        // re-read when cmux sends workspace.changed; never polled
  return VStack([
    ForEach({ items: () => spaces() ?? [], key: (w) => w.id }, (w) => Row({ title: () => w().name }))
  ])
})
```

Then, with cmux running:

```sh
cmux ext dev            # validate, build, load; then reload on every save
cmux ext dev --once --json   # one round, for an agent's loop
```

## The TypeScript API

| Name | What it is |
| --- | --- |
| `section(render)`, `pane(render)` | A sidebar section (`cmux.section/1`) and a pane (`cmux.pane/1`). Export the result under the manifest's `export` name. |
| `sidebar(render)` | The whole workspace list (`cmux.sidebar/1`), drawn in place of the built-in one once the person names the extension in `sidebar.workspaceListApp`. The built-in list is the fallback. [`examples/extensions/workspace-list`](../../../examples/extensions/workspace-list) is the built-in list rebuilt on this SDK. |
| `newTab(render)` | A whole New Tab page (`cmux.newtab/1`): the scene is the page body. It shows only once the person runs `cmux settings set tabs.newTabApp <your id>`; unset, or when the extension is hidden, disabled or fails, cmux draws its own page. Render gets `{ surface: "newTab", cwd? }`. Draws on the web New Tab page, not the native one (`tabs.nativeNewTabPage`). |
| `widget(render)` | A widget (`cmux.widget/1`): a glanceable tile the person places on the New Tab page or in the sidebar from Edit Widgets > Add Widget, as many copies as they like. The manifest's `options` name `sizes` (`small` 1x1, `medium` 2x1, `large` 2x2 tiles; the sidebar takes small and medium), `defaultSize`, `refresh.everySeconds` (at least 60) and `places` (`newtab`, `sidebar`; missing means both). Render gets `{ surface: "widget", place, size, instance, settings, refresh, now(), preview? }`; a view that reads `ctx.now()` redraws on each host tick, which comes on the wall-clock boundary and only while the tile is shown. A resize remounts at the new size. cmux ships no widgets of its own. |
| `WidgetFrame`, `WidgetTitle`, `BigNumber`, `Headline`, `Caption`, `Footnote`, `WidgetSymbol`, `Gauge`, `RowList`, `WidgetEmpty`, `bySize`, `WIDGET_TYPE`, `WIDGET_INSET`, `WIDGET_TILES` | Layout for widgets on Apple's widget type scale and 16 pt inset (12 in the sidebar): a frame, a tinted header, the big glanceable value, secondary lines, a gauge, a compact list with tinted bars, an empty state, and a pick by size. `cmux ext new NAME --kind widget` starts from them. |
| `TYPE_ROLES`, `TextIn`, `Heading`, `Label`, `Body`, `SPACE`, `Space` | The type roles (numeral, heading, title, label, body, caption, footnote) and the spacing scale (0 2 4 6 8 12 16 20 24 32 48) the helpers use. Text goes through a role and gaps through `SPACE`; `cmux ext dev` warns on a size or gap off them, a raw or unknown color, more than two accents, low contrast, and in a widget more than four type roles or text with no line limit, each with its fix. `cmux ext design FILE` runs the same check on recorded scenes. |
| `chatWidget(render)` | A chat widget (`cmux.chat.widget/1`): a card under each agent tool call whose name matches the manifest's `options.tools` (`*` matches any run of characters), and for widget parts an agent sends naming the extension. Render gets `{ surface: "chatWidget", widget: { key }, tool?: { name, title?, status?, input?, output? }, props? }`. cmux ships no widgets of its own; a missing, hidden or failing extension leaves the call as it was. Export the same render with `section(...)` to show it in the sidebar too. |
| `command(run)` | A command an extension declares in `catalog.json`; runs from the palette, the CLI or another extension. |
| `workspaces()`, `agents()`, `chats()` | Live lists: call one for the latest value; `.loading()`, `.error()`, `.refresh()`. One read however many views use it; re-read on the matching event. |
| `recentChats({limit, state?, after?})` | The newest chats, at most `limit` (1 to 1000): a New Tab page's recent chats, a waiting-on-you list (`state: "input"`), or a page of All chats (`after` the last chat of the page before). cmux reads them from its ordered chat index, so a read costs the chats it returns, never a sort of every chat. Rows carry `preview`, the last reply. |
| `on(stream, fn)` | Runs `fn` each time `stream` fires; returns the unsubscribe, and unsubscribes with the render that called it. An unknown stream throws at load. |
| `onChange(live, fn, {initial})` | Runs `fn` with each new value of a live list. |
| `EVENT_STREAMS`, `scopeFor(stream)` | The streams cmux sends and the scope each needs. |
| `cmux` | Every op cmux gives an extension (`cmux.workspace.focus`, `cmux.toast`, `cmux.watch`, `cmux.storage`, ...), typed in `cmux-app.d.ts`. |
| `cmux.time.zone(name, at?)` | Another time zone: `{zone, offsetMinutes, abbreviation}` for an IANA name at `at` (epoch ms, default now); throws `zone.unknown`. The sandbox has no `Intl`, and `toLocaleString` ignores `timeZone`, so a world clock reads the offset here and formats `new Date(now + offsetMinutes * 60000)` with the `getUTC*` methods. |
| `signal`, `computed`, `effect`, `onCleanup`, `untrack` | Reactive state: a view that reads a signal redraws only what changed. |
| `VStack`, `HStack`, `Row`, `Text`, `Panel`, `ForEach`, `Button`, `Toggle`, ... | The scene DSL cmux draws natively. Colors are theme tones (`cmux.theme.success`), never raw values. |
| `SDK_VERSION`, `API_VERSION`, `RUNTIME_VERSION` | Versions (below). |

Events (from `cmux-app-host/schema/v2/events.json`; each is an invalidation with no payload):

| Stream | Scope | Fires when |
| --- | --- | --- |
| `workspace.changed` | `workspace:read` | a workspace is created, closed, renamed, reordered, selected or restyled |
| `screen.changed`, `pane.changed`, `tab.changed` | `workspace:read` | a layout, pane or tab changes |
| `terminal.changed` | `terminal:read` | a terminal starts, ends or changes its title or folder |
| `agent.changed` | `agent:read` | an agent's state changes |
| `agent_chat.changed` | `agent_chat:read` | a chat is added, closed, renamed, read or changes state |
| `chat.changed` | `chat:read` | a listed field of a chat changes (`chat.list`; not `updated_ms` alone) |
| `settings.changed` | `settings:read` | a cmux setting changes (the file, a managed layer, Settings, the CLI); names no keys, carries no values |
| `theme.changed` | `settings:read` | the theme, app theme, theme file or edits, accent, hue, saturation or highlight color changes |
| `github.changed` | `integration:github:read` | a pull request, review, check run or suite, or commit status changes on a repository a GitHub connection covers (the Cloud's GitHub App webhooks, within seconds); its body is `{"live": bool}` when the push channel goes up or down, and a new subscriber hears that first. `cmux.watch("github.pulls")` already re-reads on it |

## Test it

`cmux-extension-sdk/testing` runs an extension the way cmux does, with no cmux running: the fake
host loads the same runtime bundle cmux ships, and the validator is the one `cmux apps validate` runs.

```ts
import { FakeHost, pack, validatePackage, manifestSchema, interfaceContract } from "cmux-extension-sdk/testing"

const host = new FakeHost(await pack("."), { app: { id: "local/my-ext", version: "0.1.0" }, apiVersion: "1.0.0" })
host.handlers = { "workspace.list": () => ({ ok: true, body: { value: [] } }) }
host.mount("s", "renderSection")
await host.settle()
```

Every first-party extension with tests runs them this way as a fork, with only this package
beside it (`bun first-party-apps/fork-check.ts`); `runtime-files.json` lists the runtime files the
package ships.

## Composer: slash commands and mentions

Two places are data in the manifest, with no script: cmux's daemon reads them and answers the
agent chat composer, so saving `cmux-app.json` updates the composer without a restart.

```json
"implements": {
  "cmux.composer.command/1": { "options": { "commands": [
    { "name": "standup", "description": "Ask for today's standup", "insert": "Write my standup notes." }
  ] } },
  "cmux.composer.mention/1": { "options": { "prefix": "ticket", "items": [
    { "id": "ENG-1", "label": "ENG-1 Login fails", "insert": "ENG-1" }
  ] } }
}
```

- `cmux.composer.command/1`: each command is a row in the composer's `/` menu; picking it writes
  `insert` over the typed `/word`. Names are lowercase letters, digits, `-` and `_`, 32 at most; a
  name the agent or cmux already has stays theirs. Up to 32 commands per extension.
- `cmux.composer.mention/1`: items the daemon ranks for a query (`apps.composer.mentions`). Up to
  200 per extension.

- `cmux.composer.chip/1`: context chips (`{"chips": [{"id", "label", "insert", "detail"?}]}`), short
  labels the person clicks to add `insert` to the draft. The daemon lists them in
  `apps.composer.list` (`chips`), in app id and manifest order, dropping a chip whose insert text
  an earlier one already writes. Up to 12 per extension.

The TypeScript types are `ComposerCommand`, `ComposerMention` and `ComposerChip`; in Rust,
`Manifest::slash_command`, `Manifest::mention` and `Manifest::composer_chip`.

## Composer model and reasoning picker

A customization can open the searchable model picker directly from the composer and choose where the active session's reasoning levels appear. Use `column` to show levels beside the model list or `separate` to show a second composer control. Removing or hiding the customization restores the configured picker. When several apps supply a layout, the first enabled, visible app in app ID order wins.

```json
"implements": {
  "cmux.composer.model.picker/1": {
    "options": { "modelMenu": "search", "reasoningMenu": "column" }
  }
}
```

The host reads model names, reasoning levels and service tiers from the active session and applies choices through its existing controls. The extension declares its layout without a script or additional permissions. Rust extensions can call `Manifest::model_picker(ReasoningMenu::Column)`.

## The Rust API

```rust
use cmux_extension_sdk::{Manifest, Region, check_package, is_valid};

let manifest = Manifest::new("local/my-ext", "My extension", "0.1.0", "My workspaces, live.")
    .section("renderSection", "Mine", "sparkles", Region::Top)
    .new_tab("renderNewTab", "Mine", "house")   // a whole New Tab page, once picked
    .widget("renderClock", "Clock", "clock", &["small", "medium"], Some(60), &[]) // a tile on New Tab and in the sidebar
    .chat_widget("renderCard", "PR", "arrow.triangle.pull", &["mcp__github__*pull_request*"]) // a card under matching tool calls
    .listen("workspace.changed")?          // asks for workspace:read
    .listen("agent_chat.changed")?;        // asks for agent_chat:read
assert!(is_valid(&manifest.validate()));
std::fs::write("cmux-app.json", serde_json::to_string_pretty(&manifest.to_json())?)?;
assert!(check_package(std::path::Path::new(".")).is_valid());
```

`EVENTS`, `SIGNALS`, `event(name)` and `signal(name)` are the same tables the TypeScript package
reads, as constants.

## What you can customize, typed

`cmux customize schema` (MCP: `customize_schema`) lists every setting key with its type, choices,
range and default, what a theme file holds and the theme tokens, the view slots and where each
goes, and every extension point with its options. Both SDKs carry the same list as types, written
from that one source (`cmux_customize::schema`), so a key that does not exist is an error, not a
guess:

```ts
import type { CmuxSettings, SettingKey, ViewSlot, CmuxViewSlots } from "cmux-extension-sdk/customize"

const key: SettingKey = "appearance.themeFile"           // a misspelled key does not type-check
const accent: CmuxSettings["appearance.accent"] = "blue"  // the value's own type
const place: CmuxViewSlots["cmux.section/1"] = "top"      // "top" | "middle" | "bottom"
```

```rust
use cmux_extension_sdk::customize::{self, keys};

let row = customize::setting(keys::APPEARANCE_THEME_FILE).unwrap(); // one constant per key
println!("{} is a {}, default {:?}", row.key, row.kind, row.default);
```

The TypeScript file (`typescript/src/generated/customize.ts`) is types only, so an `import type`
adds nothing to a bundle. It is not committed: every build of this crate writes it (`build.rs`),
`cmux ext dev` writes it beside the SDK it builds with, and `cmux customize schema --typescript`
prints it. The crate's test `the_typescript_types_in_the_checkout_are_current` fails when a
checkout's copy is stale.

## Versions

- `SDK_VERSION` (1.0.0) is this package's semver; the crate and the npm package always carry the
  same one. A removed or narrowed export is a new major.
- `API_VERSION` is the app API (`cmux app API` in `cmux-app.d.ts`). Ops are only added; an op the
  running cmux lacks answers `operation.unsupported`.
- `RUNTIME_VERSION` is the extension runtime: in TypeScript the one the extension runs in, in Rust
  the one the crate was built against (`1.2.0` added `cmux.watch`). A manifest's `engines.cmux` says which cmux it needs.
- Places carry their own major (`cmux.section/1`); a breaking change is `/2`, served beside `/1`.

## How it is made

Nothing generated is committed. Both languages read the runtime's sources in
`cmux-tui/crates/cmux-app-host`: the event streams (`schema/v2/events.json`), the op scopes and
live sources the generator already writes (`generated/scopes.json`, `generated/signals.json`,
`generated/cmux-app.d.ts`) and the runtime's version (`js/src/index.ts`). The TypeScript package
imports them; the crate's `build.rs` turns them into constants. `tools/gen-cmux-global.ts` checks
each stream's `reads` op and scope against the catalog, and the daemon's test
`every_stream_the_daemon_publishes_is_in_the_sdks_event_table` fails when cmux sends a stream the
table does not list. Publishing either package bundles these files into it.
