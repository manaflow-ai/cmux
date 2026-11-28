# cmux app runtime ABI v1 (as built)

Spec: cmux-next-spec `spec/app-platform.md` section 5.3. Runtime: `dist/cmux-app-runtime.js` (built from `src/` by `bun build.ts`; `--check` in the gate). Reference host: `test/fake-host.ts`.

## Load order
1. Define `globalThis.__cmuxAppNative` (below).
2. Evaluate `dist/cmux-app-runtime.js`.
3. Evaluate the app's `main` (a classic script from `tools/pack.ts`; it sets `globalThis.__cmuxAppExports`).
4. Call `__cmuxAppInit(JSON.stringify({app: {id, version}, settings, apiVersion, ops?, knownOps?, locale?, strings?, paletteScopes?}))`. `knownOps` lists every op this cmux version has (others reject locally with `operation.unsupported`); `ops` lists the ops the app's grant allows (known but not granted reject with `scope.missing`). The host must still check every call: the VM is untrusted. `locale` and `strings` (the app's `strings/<locale>.json`, falling back to English) feed `cmux.t()`. `paletteScopes` is the manifest's `contributes.paletteScopes` array as declared; the runtime reads each scope's `id`, `source.export` and `detail.export`.

## Host functions (`__cmuxAppNative`)
| Function | Notes |
| --- | --- |
| `call(name, paramsJSON, optionsJSON, cbId)` | Answer later with `__cmuxAppResolve(cbId, ok, json)`. ok: `{"value", "revision"?, "transaction"?, "replayed"?}`; error: `{"code", "message", "details"?, "retryable"}`. The host fills missing `machine`/`session` selectors with the current ones, mints an idempotency key for mutations when `options.idempotencyKey` is absent (reads never send one), stamps `actor = app:<id>`, `origin = script` (or `user` inside a tap handler turn) |
| `subscribe(stream, filterJSON) -> subId` / `unsubscribe(subId)` | Deliver with `__cmuxAppEvent(subId, json)`. `cmux.live(op)` subscribes to `<family>.changed` by default |
| `scene(mountId, opsJSON)` | One batch per host entry point or microtask flush |
| `timer(ms, repeat) -> id` / `clearTimer(id)` | Fire with `__cmuxAppTimer(id)`; repeating timers are floored to 1000 ms by the runtime |
| `log(level, message)` | `debug|info|warn|error` |
| `commandDone(cbId, ok, json)` | Completion of `__cmuxAppRunCommand`; ok body `{"value"}`, error body `{"code","message","details"}` |
| `paletteBatch(reqId, generation, itemsJSON, isFinal, replace)` | Items for palette request `reqId` (below). `itemsJSON` is an array of at most 200 items; `generation` echoes the request's; `replace` is true for the request's first batch and for the first live batch after a `palette.cached()` batch, false for appends. A successful request sends exactly one batch with `isFinal` true |
| `paletteDone(reqId, ok, json)` | End of a palette request. Open: ok `{"count"}`. Detail: ok body is the detail object or `null`. Error: `{"code","message","details"}`. Not sent after `__cmuxAppPaletteCancel` or after a newer open superseded the request |

Host-provided op names beyond the catalog: `action.run {id, args}`, `action.list`, `app.storage.get|set|delete|keys`, `app.settings.set {values}` (writes the app's settings in cmux.json after schema validation), `net.fetch {url, method, headers, body}` -> `{status, headers, body}`, `integration.request {provider, method, path, body?}`, `clipboard.write {text}` (scope `clipboard:write`). Scopes: `generated/scopes.json`. `signal` in call options never leaves the VM.

## Gesture tokens
The VM is untrusted: these rules are enforced by the host, and the runtime only carries tokens.

- **Minting.** The host mints a token only for a user gesture in that client: a user event it dispatches (`tap`, `menu`, `submit`, ... in the event payload) or a command it runs because of one (palette Return or click on a row, a menu item, a shortcut). It never mints one for `cmux apps run`, MCP, a deeplink, an automation, or `action.run` called by app code, even when that call presents a live token, so tokens cannot renew themselves through command chains. It never mints one for another app's command because of this app's row.
- **Binding and lifetime.** A token is bound to the app id and to one invocation (one event or one command run). An event token lives 10 s. A command token is revoked at `commandDone` or after 2 s, whichever comes first. The host checks the token on every call; the runtime's own bookkeeping is a convenience, never the limit.
- **One rule for use.** A token allows one change of view state (focus, selection, showing or closing a window, workspace, tab or pane, navigation). The first mutation that changes view state and presents a live token runs with origin `user` and spends the token. Reads and mutations that do not change view state (the app's own storage and settings, `clipboard.write`) run with origin `user` while the token is live and do not spend it. Every other call runs with origin `script`; the host decides only from the token it sees.
- **Carrying.** While an event handler runs synchronously, every call carries the event token; after its first `await` only calls that pass `{gesture: cmux.gesture()}` captured earlier do. A command's token arrives in `__cmuxAppRunCommand`'s `ctxJSON` (`{gesture}`, palette-scopes.md 6.7 B2) and is `ctx.gesture`; calls through the command's `ctx.cmux` carry it across awaits, and `ctx.cmux.gesture()` returns it. The global `cmux` carries a command token only when the app passes it explicitly. When a call has several: `ctx.cmux`'s token, then an explicit `options.gesture`, then the ambient handler token.

## Palette actions run by the host
When the user runs a palette row (Return, click, Cmd-Return), the host runs the row's `ActionRef` itself with origin `user`; no app code runs unless the ref is one of the app's own commands. Before it runs a ref, the host checks:
- the ref id is an op or action the app's grants cover, or one of the app's own commands (`app:<this app id>#<command>`); for `action.run` it checks the inner action id the same way; a ref to another app's command is refused (the user can run that app's scope or command directly);
- `args` against the op's (or the command's `arguments`) schema;
- the manifest's `primary` and `emptyState.action` the same way, with `{id}` of the row as args for `primary`.
Only an own-command ref gets a fresh command token (see Gesture tokens).

## Runtime entry points
`__cmuxAppInit(json)`, `__cmuxAppSetSettings(json)`, `__cmuxAppMount(mountId, exportName, ctxJSON) -> "" | error`, `__cmuxAppUnmount(mountId)`, `__cmuxAppDispatch(mountId, nodeId, event, payloadJSON)` (`tap`, `move {id,index,extra}`, `dragChange {state}`, `submit {text}`, `edit {text}`, `cancel`, `menu {path:[int]}`), `__cmuxAppRunCommand(exportName, argsJSON, cbId, ctxJSON?)`, `__cmuxAppPaletteOpen(scopeId, kind, query, generation, ctxJSON, reqId) -> "" | error`, `__cmuxAppPaletteCancel(reqId)`, `__cmuxAppPaletteDetail(scopeId, itemId, reqId)`, `__cmuxAppResolve`, `__cmuxAppEvent`, `__cmuxAppTimer`, `__cmuxAppFlush()` (hosts whose engine needs an explicit microtask drain, such as QuickJS `JS_ExecutePendingJob`, drain jobs and then call this). `__cmuxAppRuntimeVersion` is a string (`1.1.0` adds the palette entry points and the command gesture).

`__cmuxAppRunCommand` `ctxJSON` (optional): `{"gesture"}`, minted only as Gesture tokens describes (palette-scopes.md 6.7 B2). The command's second argument is `{app, gesture?, cmux}`; `ctx.cmux` is a per-invocation copy of the global whose op calls carry the token. The runtime stops attaching it when the command settles; the host's revocation at `commandDone` or 2 s is the real limit.

## Palette sources (palette-scopes.md section 6)
App exports wrap functions: `palette.snapshot(ctx => items)`, `palette.query(async function* (query, ctx) { yield items })`, `palette.detail((itemId, ctx) => detail)`. `palette.cached()` (yielded from a query source) sends the last complete result of the longest cached prefix of the query for the same scope, session, drilled row (`context`) and filter, kept in the VM (32 queries per key, at most 1000 rows each); that batch is provisional and the next live batch replaces it. `act(op, args, {title?, symbol?})` builds `ActionRef {id, args, title?, symbol?}`. `palette` and `act` are globals and members of `cmux`.

- `__cmuxAppPaletteOpen(scopeId, kind, query, generation, ctxJSON, reqId)`: `scopeId` is the manifest scope id (`notes`, not `app:<id>#notes`); `kind` is `snapshot` or `query` and must match the export's wrapper; `ctxJSON` is `{session?, context?, filter?}` (`session` is the host's palette level: a new open with the same scope and session aborts the older request, which then sends nothing more; `context` is the drilled or entered row id; `filter` the chosen filter id). The source gets `ctx = {scope, generation, signal, session?, context?, filter?}`; `signal` is an AbortSignal-like object (`aborted`, `reason`, `addEventListener("abort")`, `throwIfAborted()`), and `cmux` calls given `{signal}` reject with `aborted` when it fires. Snapshots run once per call (the host decides when: on an `invalidatedBy` event, never per keystroke) and are sent in chunks of 200. A query source that is a plain async function returning an array sends one final batch.
- `__cmuxAppPaletteCancel(reqId)`: aborts the signal; nothing more is sent for `reqId`.
- `__cmuxAppPaletteDetail(scopeId, itemId, reqId)`: runs the scope's `detail` export; the answer is `paletteDone(reqId, ok, detail)`.

Items: `{id, title, subtitle?, symbol?, keywords?, accessory?, actions?: [ActionRef], drill?, enters?}`, plain JSON. The runtime refuses a function, symbol, bigint or cycle anywhere in an item (`palette.invalid`), then serializes the item and validates the serialized JSON (so a `toJSON` cannot change what was checked): shape, at most 2 KiB of UTF-8 (`palette.limit`). A snapshot has at most 10000 items, a yield at most 200, and a query request at most 1000 rows in total (more ends the request early with `{count, truncated: true}`); a refused item or snapshot ends the request with `paletteDone(false)`. A detail is at most 64 KiB.

The host does not trust these checks. It re-parses and re-validates every `paletteBatch` (item shape, 2 KiB per item, 200 per batch, 10000 per snapshot request and 1000 per query request in total, no non-JSON values) and drops a batch whose `reqId` is unknown, closed, cancelled or superseded, or whose `generation` is not the request's.

Prefixes (`contributes.paletteScopes[].prefix`) belong to first-party apps (`cmux/`). The host and the registry enforce it when they load a manifest (a third-party prefix is dropped with a notice), not only `cmux apps validate`. Keywords must contain a letter or digit, so a symbol-only keyword cannot imitate a built-in prefix. Error codes: `palette.scope` (no such scope in `paletteScopes`), `palette.kind`, `export.missing`, `palette.invalid`, `palette.limit`, `aborted`.

Promise continuations run as microtasks: QuickJS hosts must drain pending jobs after every entry point; JavaScriptCore drains them at the end of each outermost call.

## Scene ops
`create {id, type, props}`, `update {id, props}` (null deletes), `children {id, children}` (full ordered list), `remove {id}` (node and subtree), `root {id}`. Node types: `VStack HStack ZStack LazyVStack Group ForEach Reorderable Text Icon Image Button Menu Spacer Divider Circle Capsule Rectangle RoundedRectangle ProgressView TextField Row Badge EmptyState`. `Group` and `ForEach` lay their children out inline in the parent. Handler presence is a prop: `onTap`, `onMove`, `onDragChange`, `onSubmit`, `onEdit`, `onCancel` = true. `menu` is `[{title, destructive?, disabled?, symbol?, children?} | {divider: true}]`.

Props: text props (`text`, `title`, `subtitle`, `badge`, `placeholder`, `help`), `font` (`largeTitle title title2 title3 headline subheadline body callout caption caption2` or a point size), `weight`, `italic`, `monospaced`, `color`/`fill`/`stroke`/`background`/`hoverBackground`/`borderColor`/`tint`/`tone` (semantic tokens `primary secondary tertiary accent separator success warning danger hover selected`, or `#RRGGBB[AA]`), `lineLimit`, `truncation`, `marquee`, `fade`, `padding` (number or `{top,leading,bottom,trailing}`), `paddingHorizontal`, `paddingVertical`, `frame` (`{width,height,minWidth,maxWidth,minHeight,maxHeight}`, `"infinity"` allowed), `layoutPriority`, `fixedSize`, `cornerRadius`, `borderWidth`, `opacity`, `strokeWidth`, `size`, `rotation`, `cursor`, `fixed`, `destructive`, `disabled`, `spacing`, `symbol`, `src` (bundle path), `value` (ProgressView), `unread`, `selected`, `accessory`, `autofocus`.

Limits: 4096 nodes per mount, depth 64 (render fails with `app.limit`).
