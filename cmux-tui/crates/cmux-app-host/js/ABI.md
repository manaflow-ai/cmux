# cmux app runtime ABI v1 (as built)

Spec: cmux-next-spec `spec/app-platform.md` section 5.3. Runtime: `dist/cmux-app-runtime.js` (built from `src/` by `bun build.ts`; `--check` in the gate). Reference host: `test/fake-host.ts`.

## Load order
1. Define `globalThis.__cmuxAppNative` (below).
2. Evaluate `dist/cmux-app-runtime.js`.
3. Evaluate the app's `main` (a classic script from `tools/pack.ts`; it sets `globalThis.__cmuxAppExports`).
4. Call `__cmuxAppInit(JSON.stringify({app: {id, version}, settings, apiVersion, ops?, knownOps?, locale?, strings?}))`. `knownOps` lists every op this cmux version has (others reject locally with `operation.unsupported`); `ops` lists the ops the app's grant allows (known but not granted reject with `scope.missing`). The host must still check every call: the VM is untrusted. `locale` and `strings` (the app's `strings/<locale>.json`, falling back to English) feed `cmux.t()`.

## Host functions (`__cmuxAppNative`)
| Function | Notes |
| --- | --- |
| `call(name, paramsJSON, optionsJSON, cbId)` | Answer later with `__cmuxAppResolve(cbId, ok, json)`. ok: `{"value", "revision"?, "transaction"?, "replayed"?}`; error: `{"code", "message", "details"?, "retryable"}`. The host fills missing `machine`/`session` selectors with the current ones, mints an idempotency key for mutations when `options.idempotencyKey` is absent (reads never send one), stamps `actor = app:<id>`, `origin = script` (or `user` inside a tap handler turn) |
| `subscribe(stream, filterJSON) -> subId` / `unsubscribe(subId)` | Deliver with `__cmuxAppEvent(subId, json)`. `cmux.live(op)` subscribes to `<family>.changed` by default |
| `scene(mountId, opsJSON)` | One batch per host entry point or microtask flush |
| `timer(ms, repeat) -> id` / `clearTimer(id)` | Fire with `__cmuxAppTimer(id)`; repeating timers are floored to 1000 ms by the runtime |
| `log(level, message)` | `debug|info|warn|error` |
| `commandDone(cbId, ok, json)` | Completion of `__cmuxAppRunCommand`; ok body `{"value"}`, error body `{"code","message","details"}` |

Host-provided op names beyond the catalog: `action.run {id, args}`, `action.list`, `app.storage.get|set|delete|keys`, `app.settings.set {values}` (writes the app's settings in cmux.json after schema validation), `net.fetch {url, method, headers, body}` -> `{status, headers, body}`, `integration.request {provider, method, path, body?}`. Scopes: `generated/scopes.json`.

## Gesture tokens
The host attaches `gesture` (an opaque token) to the payload of every user event it dispatches (`tap`, `menu`, `submit`, ...). While the handler runs synchronously, every call carries `options.gesture`; after its first `await` only calls that pass `{gesture: cmux.gesture()}` captured earlier do. A mutation that presents a live token (10 s window, that app only) runs with origin `user` and uses the token up, so one user event allows one focus or selection change; reads may present it without spending it.

## Runtime entry points
`__cmuxAppInit(json)`, `__cmuxAppSetSettings(json)`, `__cmuxAppMount(mountId, exportName, ctxJSON) -> "" | error`, `__cmuxAppUnmount(mountId)`, `__cmuxAppDispatch(mountId, nodeId, event, payloadJSON)` (`tap`, `move {id,index,extra}`, `dragChange {state}`, `submit {text}`, `edit {text}`, `cancel`, `menu {path:[int]}`), `__cmuxAppRunCommand(exportName, argsJSON, cbId)`, `__cmuxAppResolve`, `__cmuxAppEvent`, `__cmuxAppTimer`, `__cmuxAppFlush()` (hosts whose engine needs an explicit microtask drain, such as QuickJS `JS_ExecutePendingJob`, drain jobs and then call this). `__cmuxAppRuntimeVersion` is a string.

Promise continuations run as microtasks: QuickJS hosts must drain pending jobs after every entry point; JavaScriptCore drains them at the end of each outermost call.

## Scene ops
`create {id, type, props}`, `update {id, props}` (null deletes), `children {id, children}` (full ordered list), `remove {id}` (node and subtree), `root {id}`. Node types: `VStack HStack ZStack LazyVStack Group ForEach Reorderable Text Icon Image Button Menu Spacer Divider Circle Capsule Rectangle RoundedRectangle ProgressView TextField Row Badge EmptyState`. `Group` and `ForEach` lay their children out inline in the parent. Handler presence is a prop: `onTap`, `onMove`, `onDragChange`, `onSubmit`, `onEdit`, `onCancel` = true. `menu` is `[{title, destructive?, disabled?, symbol?, children?} | {divider: true}]`.

Props: text props (`text`, `title`, `subtitle`, `badge`, `placeholder`, `help`), `font` (`largeTitle title title2 title3 headline subheadline body callout caption caption2` or a point size), `weight`, `italic`, `monospaced`, `color`/`fill`/`stroke`/`background`/`hoverBackground`/`borderColor`/`tint`/`tone` (semantic tokens `primary secondary tertiary accent separator success warning danger hover selected`, or `#RRGGBB[AA]`), `lineLimit`, `truncation`, `marquee`, `fade`, `padding` (number or `{top,leading,bottom,trailing}`), `paddingHorizontal`, `paddingVertical`, `frame` (`{width,height,minWidth,maxWidth,minHeight,maxHeight}`, `"infinity"` allowed), `layoutPriority`, `fixedSize`, `cornerRadius`, `borderWidth`, `opacity`, `strokeWidth`, `size`, `rotation`, `cursor`, `fixed`, `destructive`, `disabled`, `spacing`, `symbol`, `src` (bundle path), `value` (ProgressView), `unread`, `selected`, `accessory`, `autofocus`.

Limits: 4096 nodes per mount, depth 64 (render fails with `app.limit`).
