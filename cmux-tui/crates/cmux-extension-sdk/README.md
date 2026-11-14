# cmux extension SDK

Change cmux to fit how you work: add a sidebar section, open your own pane, react when a
workspace, an agent or a chat changes, and share it as an extension. cmux reloads it on every
save while you work on it.

One SDK, two languages, one version (1.0.0), made from the runtime's own tables (no copies):

| | TypeScript (`typescript/`, package `cmux-extension-sdk`) | Rust (this crate, `cmux-extension-sdk`) |
| --- | --- | --- |
| For | the extension's own code, which cmux runs in its sandbox | tools, tests and servers around an extension |
| Gives | places (`section`, `pane`, `command`), live lists (`workspaces`, `agents`, `chats`), events (`on`, `onChange`), the scene DSL (`VStack`, `Row`, ...), `cmux` (every op, typed) | versions, the event and signal tables with their scopes, `Manifest` (a typed `cmux-app.json` builder), `validate` and `check_package` (cmux's own validator) |

The working example is [`examples/extensions/activity`](../../../examples/extensions/activity):
a sidebar section and a pane, built only against this SDK.

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
| `command(run)` | A command an extension declares in `catalog.json`; runs from the palette, the CLI or another extension. |
| `workspaces()`, `agents()`, `chats()` | Live lists: call one for the latest value; `.loading()`, `.error()`, `.refresh()`. One read however many views use it; re-read on the matching event. |
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

## The Rust API

```rust
use cmux_extension_sdk::{Manifest, Region, check_package, is_valid};

let manifest = Manifest::new("local/my-ext", "My extension", "0.1.0", "My workspaces, live.")
    .section("renderSection", "Mine", "sparkles", Region::Top)
    .listen("workspace.changed")?          // asks for workspace:read
    .listen("agent_chat.changed")?;        // asks for agent_chat:read
assert!(is_valid(&manifest.validate()));
std::fs::write("cmux-app.json", serde_json::to_string_pretty(&manifest.to_json())?)?;
assert!(check_package(std::path::Path::new(".")).is_valid());
```

`EVENTS`, `SIGNALS`, `event(name)` and `signal(name)` are the same tables the TypeScript package
reads, as constants.

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
