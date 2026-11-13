// Cross-file leak detector for `bun test` (test/preload.ts installs it).
//
// bun runs every test file in one process with one module cache, so whatever a file leaves behind is
// the next file's starting state: a store it filled, a timer still pending, a listener on a shared
// global, a global it installed and never restored. Each such file passes alone and the folder
// fails whole (AllChatsList.test.tsx left device chats that NewTabScreen.test.tsx then drew). After
// every checked test file (CHECKED below) this file looks at what the file left behind. A file
// starts when bun loads it, before its static imports run, so what an import registers while it
// loads (a timer, a listener) is the file's too; such a listener counts with the module state.
//
// - Module state. A loader hook registers every top-level `let` binding, every top-level
//   `new Map` / `new Set`, every other top-level const that holds an object, array or class
//   instance that is not frozen, and every top-level class (its statics) of every source module
//   under src/agent-session in one registry, with the
//   value it held when the module finished loading (a change one module's load makes to another's
//   state counts as loaded too: a registry other modules fill as they load). No module opts in, so
//   a store is in the registry the moment a test loads it. After each file the registry is drained:
//   every binding and collection is put back to its loaded value, and every object store to its
//   loaded properties (and the entries of each Map, Set or array it holds directly), so the next
//   file starts on the state a fresh process would give it. A `let` that still holds its loaded
//   Map, Set, array or object is checked for what that value holds too (`cache.set(...)` behind
//   `let cache = new Map()`), not only for being set to another value.
// - Timers: a global setTimeout/setInterval the file started that is still pending is cleared, so it
//   cannot fire into the next file.
// - Listeners: a listener the file added to globalThis and did not remove fails the file; a `once`
//   listener counts until it fires, and one added with a signal until the signal aborts.
// - Globals: a globalThis key the file added, replaced or deleted (window, document, HTMLElement,
//   localStorage, ...) and did not restore fails the file, and so does a property it defined on a
//   global document (Object.defineProperty(document, ...)) that outlives the file.
// - Module mocks: bun's mock.module replaces a module for every later file too. A module the file
//   mocked and did not mock back to its real exports fails the file (and is put back).
//
// Failures name what was left and where. Module state and timers are a ratchet, since most files
// leave a cache or counter behind today: test/support/leak-baseline.json lists what each file leaves,
// and a file fails when it leaves any item its baseline does not list, naming each (compared by
// identity, so a fixed leak never pays for a new one). A listed item the file no longer leaves is
// named as stale, asking to lower its baseline (`bun scripts/leak-baseline.ts FILE`, which
// can only lower counts; raising one is a hand edit to the JSON). Each process prints its total
// (`agent-session leaks: N (baseline B) in F test files`). What a file leaves can depend on the files
// run before it in one process; such items carry " (with other files)" in the baseline and count
// only then, not when the file runs alone, as CI runs it. The drain gives the next file a clean
// start either way. `CMUX_TEST_LEAKS=report` lists every leak and fails nothing,
// `CMUX_TEST_LEAKS=strict` fails every leak, `CMUX_TEST_LEAKS=off` turns the detector off.
// `CMUX_TEST_LEAKS_RECORD=FILE` appends each file's items as JSON lines (for the baseline script).
// `CMUX_TEST_LEAKS_SCOPE=all` checks every test file, not only src/agent-session's.
import { mock } from "bun:test";
import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, statSync, writeSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const mode = process.env.CMUX_TEST_LEAKS ?? "on";
/// Source modules whose top-level state is registered and drained.
const WATCHED = /\/src\/agent-session\/.*\.tsx?$/;
/// Test files checked after they run.
const CHECKED = process.env.CMUX_TEST_LEAKS_SCOPE === "all" ? /\.test\.tsx?$/ : /\/src\/agent-session\/.*\.test\.tsx?$/;

type Binding = { name: string; get: () => unknown; set: (value: unknown) => void };
type Collection = { name: string; get: () => unknown };
type Entries = [unknown, unknown][];
/// An object store's own properties, and the entries of each Map, Set or array it holds directly.
type Shape = { props: Map<PropertyKey, PropertyDescriptor>; inner: Map<PropertyKey, Entries> };
/// What a store holds: a Map's or Set's entries, or an object store's shape. A `let` binding records
/// it for the value it holds, so a store changed in place behind the same binding counts too.
type Contents = { entries: Entries } | { shape: Shape } | undefined;
/// A binding's value and what that value holds.
type Held = { value: unknown; contents: Contents };
type Tracked =
  | { kind: "binding"; path: string; binding: Binding; loaded: Held }
  | { kind: "collection"; path: string; name: string; value: Map<unknown, unknown> | Set<unknown>; loaded: Entries }
  | { kind: "object"; path: string; name: string; value: object; loaded: Shape };

const tracked: Tracked[] = [];

function entriesOf(value: Map<unknown, unknown> | Set<unknown>): Entries {
  return value instanceof Map ? [...value.entries()] : [...value].map((item) => [item, item]);
}

function sameEntries(a: Entries, b: Entries): boolean {
  if (a.length !== b.length) return false;
  const byKey = new Map(a);
  return b.every(([key, value]) => byKey.has(key) && Object.is(byKey.get(key), value));
}

/// Whether `value` is a Map, Set or array: the containers whose entries a store's shape records.
function isContainer(value: unknown): value is Map<unknown, unknown> | Set<unknown> | unknown[] {
  return value instanceof Map || value instanceof Set || Array.isArray(value);
}

/// The key an array's length is recorded under among its entries (never an index).
const LENGTH = Symbol("length");

/// A container's entries: a Map's or Set's, or an array's own elements by index and its length, so
/// `arr.length = 10` on an empty array (all holes, no element) still reads as a change.
function containerEntries(value: Map<unknown, unknown> | Set<unknown> | unknown[]): Entries {
  if (!Array.isArray(value)) return entriesOf(value);
  const entries: Entries = Object.keys(value).map((key) => [Number(key), value[Number(key)]]);
  entries.push([LENGTH, value.length]);
  return entries;
}

/// Own property keys a class constructor always has; its statics are the rest.
const CLASS_KEYS = new Set<PropertyKey>(["length", "name", "prototype"]);

/// An object store's shape: its own properties (an array's elements too) and, one level down, the
/// entries of each Map, Set or array a property holds. Getters are recorded, never called.
function shapeOf(value: object): Shape {
  const props = new Map<PropertyKey, PropertyDescriptor>();
  const inner = new Map<PropertyKey, Entries>();
  const constructorLike = typeof value === "function";
  for (const key of Reflect.ownKeys(value)) {
    if (constructorLike && CLASS_KEYS.has(key)) continue;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor) continue;
    props.set(key, descriptor);
    if ("value" in descriptor && isContainer(descriptor.value)) inner.set(key, containerEntries(descriptor.value));
  }
  return { props, inner };
}

function sameShape(a: Shape, b: Shape): boolean {
  if (a.props.size !== b.props.size) return false;
  for (const [key, before] of a.props) {
    const after = b.props.get(key);
    if (!after || !Object.is(before.value, after.value) || before.get !== after.get || before.set !== after.set)
      return false;
  }
  for (const [key, entries] of a.inner) {
    const now = b.inner.get(key);
    if (!now || !sameEntries(entries, now)) return false;
  }
  return true;
}

/// Puts an object store back to `shape`: added properties go, changed ones get their loaded value,
/// and each Map, Set or array it held directly gets its loaded entries back.
function restoreShape(value: object, shape: Shape): void {
  const target = value as Record<PropertyKey, unknown>;
  // An array is emptied first; its loaded elements are put back below with its other properties.
  if (Array.isArray(value)) value.length = 0;
  const constructorLike = typeof value === "function";
  for (const key of Reflect.ownKeys(value)) {
    if (constructorLike && CLASS_KEYS.has(key)) continue;
    if (Array.isArray(value) && key === "length") continue;
    if (!shape.props.has(key)) Reflect.deleteProperty(target, key);
  }
  for (const [key, descriptor] of shape.props) {
    // An array's length goes back after its elements (defining an element can lengthen it).
    if (Array.isArray(value) && key === "length") continue;
    try {
      Object.defineProperty(value, key, descriptor);
    } catch {
      // A non-configurable property it cannot change back; the next check names it again.
    }
  }
  for (const [key, entries] of shape.inner) {
    const container = target[key];
    if (container instanceof Map) {
      container.clear();
      for (const [k, v] of entries) container.set(k, v);
    } else if (container instanceof Set) {
      container.clear();
      for (const [k] of entries) container.add(k);
    } else if (Array.isArray(container)) {
      container.length = 0;
      for (const [k, v] of entries) if (k !== LENGTH) container[k as number] = v;
      const length = entries.find(([k]) => k === LENGTH);
      if (length) container.length = length[1] as number;
    }
  }
  const length = Array.isArray(value) ? shape.props.get("length") : undefined;
  if (length && "value" in length) (value as unknown[]).length = length.value as number;
}

function contentsOf(value: unknown): Contents {
  if (value instanceof Map || value instanceof Set) return { entries: entriesOf(value) };
  return isObjectStore(value) ? { shape: shapeOf(value) } : undefined;
}

function sameContents(a: Contents, b: Contents): boolean {
  if (!a || !b) return a === b;
  if ("entries" in a) return "entries" in b && sameEntries(a.entries, b.entries);
  return "shape" in b && sameShape(a.shape, b.shape);
}

/// Puts a Map, Set or object store a binding holds back to `contents`.
function restoreContents(value: unknown, contents: Contents): void {
  if (!contents) return;
  if ("shape" in contents) {
    if (value !== null && typeof value === "object") restoreShape(value, contents.shape);
    return;
  }
  if (!(value instanceof Map || value instanceof Set)) return;
  value.clear();
  for (const [key, entry] of contents.entries)
    if (value instanceof Map) value.set(key, entry);
    else value.add(key);
}

function held(binding: Binding): Held {
  const value = binding.get();
  return { value, contents: contentsOf(value) };
}

/// What a tracked item holds now, in the form its `loaded` keeps.
type Loaded = Tracked["loaded"];

function current(item: Tracked): Loaded {
  if (item.kind === "binding") return held(item.binding);
  return item.kind === "object" ? shapeOf(item.value) : entriesOf(item.value);
}

function same(item: Tracked, a: Loaded, b: Loaded): boolean {
  if (item.kind === "binding") {
    const [before, after] = [a as Held, b as Held];
    return Object.is(before.value, after.value) && sameContents(before.contents, after.contents);
  }
  return item.kind === "object" ? sameShape(a as Shape, b as Shape) : sameEntries(a as Entries, b as Entries);
}

/// Whether a top-level const holds a store whose contents can change: an object, array or class
/// instance that is not frozen. Functions, promises and built-in values that hold no store
/// (patterns, dates, errors) are left out.
function isObjectStore(value: unknown): value is object {
  if (value === null || typeof value !== "object") return false;
  if (Object.isFrozen(value) || value === globalThis) return false;
  // A window, document or DOM node a module holds is the environment, not a store of its own.
  const record = value as { nodeType?: unknown; window?: unknown };
  if (typeof record.nodeType === "number" || record.window === value) return false;
  if (Object.prototype.toString.call(value) === "[object Module]") return false;
  return !(
    value instanceof Promise ||
    value instanceof RegExp ||
    value instanceof Date ||
    value instanceof Error ||
    value instanceof WeakMap ||
    value instanceof WeakSet ||
    ArrayBuffer.isView(value)
  );
}

/// Snapshots taken when a watched module starts loading, one per module still loading.
const loading: Loaded[][] = [];

/// Prepended to every watched module: remembers the registry's state as the module starts.
function moduleStart(): void {
  loading.push(tracked.map(current));
}

/// Appended to every watched module. A change the module's own load made to state already in the
/// registry is part of the loaded state (a module that registers itself in another's map), not a
/// leak; then the module's own state joins the registry as loaded.
function moduleEnd(path: string, bindings: Binding[], collections: Collection[], objects: Collection[] = []): void {
  const before = loading.pop();
  if (before)
    before.forEach((value, index) => {
      const item = tracked[index];
      const now = current(item);
      // `now` came from current(item), so it has the form of this item's own `loaded`.
      if (!same(item, value, now)) (item as { loaded: Loaded }).loaded = now;
    });
  for (const binding of bindings) {
    try {
      tracked.push({ kind: "binding", path, binding, loaded: held(binding) });
    } catch {
      // A `let` the source scan found inside a string or comment, not a binding.
    }
  }
  for (const { name, get } of collections) {
    try {
      const value = get();
      if (value instanceof Map || value instanceof Set)
        tracked.push({ kind: "collection", path, name, value, loaded: entriesOf(value) });
    } catch {
      // Same: not a real top-level collection.
    }
  }
  // Other top-level consts and classes: an object, array or class instance a module keeps state in
  // (dictation's `level`, a cache class's instance) and a class's statics.
  const seen = new Set<unknown>(tracked.map((item) => (item.kind === "binding" ? undefined : item.value)));
  for (const { name, get } of objects) {
    try {
      const value = get();
      const store = typeof value === "function" ? isClass(value) : isObjectStore(value);
      if (!store || seen.has(value) || value instanceof Map || value instanceof Set) continue;
      seen.add(value);
      tracked.push({ kind: "object", path, name, value: value as object, loaded: shapeOf(value as object) });
    } catch {
      // Same: not a real top-level declaration.
    }
  }
}

/// A class declared at the top level: its statics (`static live`) are module state too, set now or later.
function isClass(value: unknown): boolean {
  return typeof value === "function" && /^class\b/.test(Function.prototype.toString.call(value));
}

function shortPath(path: string): string {
  const at = path.lastIndexOf("/src/");
  return at >= 0 ? path.slice(at + 1) : path;
}

/// Puts every registered binding and collection back to its loaded value; names the ones it reset.
function drainModuleState(): string[] {
  const drained: string[] = [];
  for (const item of tracked) {
    if (item.kind === "binding") {
      const now = item.binding.get();
      const { value, contents } = item.loaded;
      if (!Object.is(now, value)) {
        drained.push(`module state: ${shortPath(item.path)} \`${item.binding.name}\` is still set`);
        item.binding.set(value);
      } else if (!sameContents(contents, contentsOf(now)))
        drained.push(`module state: ${shortPath(item.path)} \`${item.binding.name}\` changed since it loaded`);
      else continue;
      // The loaded value may have been changed in place before the binding moved off it.
      restoreContents(value, contents);
      continue;
    }
    if (item.kind === "object") {
      if (sameShape(item.loaded, shapeOf(item.value))) continue;
      drained.push(`module state: ${shortPath(item.path)} \`${item.name}\` changed since it loaded`);
      restoreShape(item.value, item.loaded);
      continue;
    }
    const now = entriesOf(item.value);
    if (sameEntries(item.loaded, now)) continue;
    drained.push(`module state: ${shortPath(item.path)} \`${item.name}\` holds entries it did not hold when loaded`);
    item.value.clear();
    for (const [key, value] of item.loaded)
      if (item.value instanceof Map) item.value.set(key, value);
      else item.value.add(key);
  }
  return drained;
}

// --- The loader: registers watched modules' state; appends the check to checked test files. ---

/// Top-level `let` bindings (one name per declaration, as the formatter writes them) and top-level
/// `const name = new Map|Set` collections in a module's source.
/// Words a `const` or `class` line can start with that are not a name (`const enum X`).
const RESERVED = new Set(["enum", "await", "yield", "let", "static", "implements", "interface"]);

export function topLevelState(source: string): { lets: string[]; collections: string[]; objects: string[] } {
  const lets = [...source.matchAll(/^(?:export )?let ([A-Za-z_$][\w$]*)/gm)].map((match) => match[1]);
  const collections = [
    ...source.matchAll(/^(?:export )?const ([A-Za-z_$][\w$]*)(?:\s*:[^=\n]+)?\s*=\s*new (?:Map|Set)\b/gm),
  ].map((match) => match[1]);
  const known = new Set(collections);
  // Every other top-level const and class: which of them hold a store is decided on their values
  // when the module has loaded (moduleEnd).
  const objects = [
    ...[...source.matchAll(/^(?:export )?const ([A-Za-z_$][\w$]*)\b/gm)].map((match) => match[1]),
    ...[...source.matchAll(/^(?:export )?(?:default )?(?:abstract )?class ([A-Za-z_$][\w$]*)\b/gm)].map(
      (match) => match[1],
    ),
  ].filter((name) => !known.has(name) && !RESERVED.has(name));
  return { lets, collections, objects };
}

function instrumentModule(path: string, source: string): string {
  const { lets, collections, objects } = topLevelState(source);
  const bindings = lets
    .map((name) => `{ name: ${JSON.stringify(name)}, get: () => ${name}, set: (__v: any) => { ${name} = __v; } }`)
    .join(", ");
  const getter = (name: string) => `{ name: ${JSON.stringify(name)}, get: () => ${name} }`;
  const colls = collections.map(getter).join(", ");
  const objs = objects.map(getter).join(", ");
  return (
    `(globalThis as any).__cmuxModuleStart?.();\n${source}\n` +
    `;(globalThis as any).__cmuxModuleEnd?.(${JSON.stringify(path)}, [${bindings}], [${colls}], [${objs}]);\n`
  );
}

function instrumentTest(path: string, source: string): string {
  return (
    `(globalThis as any).__cmuxStartFile?.(${JSON.stringify(path)});\n${source}\n` +
    'import { afterAll as __cmuxLeakAfterAll } from "bun:test";\n' +
    // Registered after the file's own top-level afterAll hooks, so it runs after their teardown.
    "__cmuxLeakAfterAll(() => (globalThis as any).__cmuxCheckFile?.(import.meta.path));\n"
  );
}

// --- Timers, listeners and globals: snapshot when a checked file starts, compare when it ends. ---

type Pending = { kind: "setTimeout" | "setInterval"; handle: unknown; where: string };
const pendingTimers = new Map<number, Pending>();
let realClearTimeout: typeof clearTimeout = clearTimeout;
let realClearInterval: typeof clearInterval = clearInterval;

/// Where a timer was started, without line numbers so the key survives edits above it: the first
/// frame in this repository's sources (else the first library frame), as `fn (path)`.
function timerSite(): string {
  const frames = (new Error().stack ?? "")
    .split("\n")
    .slice(2)
    .map((line) => line.trim().replace(/^at /, ""))
    .filter(
      (line) => line && !line.includes("leakDetector") && !line.includes("native:") && !line.endsWith("(native)"),
    );
  const parse = (frame: string) => {
    const match = /^(?:(.*?) \()?(.+?):\d+:\d+\)?$/.exec(frame);
    if (!match) return frame;
    const file = match[2];
    const at = Math.max(file.lastIndexOf("/src/"), file.lastIndexOf("/test/"), file.lastIndexOf("/node_modules/"));
    return `${match[1] || "<anonymous>"} (${at >= 0 ? file.slice(at + 1) : file})`;
  };
  const own = frames.find((frame) => /\/(src|test)\//.test(frame) && !frame.includes("/node_modules/"));
  return parse(own ?? frames[0] ?? "unknown");
}

function callerFrame(): string {
  const lines = (new Error().stack ?? "").split("\n").slice(2);
  const frame = lines.find((line) => !line.includes("leakDetector")) ?? "";
  return frame.trim().replace(/^at /, "");
}

function wrapTimers(): void {
  const scope = globalThis as typeof globalThis & Record<string, unknown>;
  const realTimeout = scope.setTimeout;
  const realInterval = scope.setInterval;
  realClearTimeout = scope.clearTimeout;
  realClearInterval = scope.clearInterval;
  const timeout = (handler: unknown, ms?: number, ...args: unknown[]) => {
    let id = Number.NaN;
    const handle = realTimeout(
      (...inner: unknown[]) => {
        pendingTimers.delete(id);
        if (typeof handler === "function") handler(...inner);
      },
      ms,
      ...args,
    );
    id = Number(handle);
    pendingTimers.set(id, { kind: "setTimeout", handle, where: timerSite() });
    return handle;
  };
  const interval = (handler: unknown, ms?: number, ...args: unknown[]) => {
    const handle = realInterval(handler as () => void, ms, ...args);
    pendingTimers.set(Number(handle), { kind: "setInterval", handle, where: timerSite() });
    return handle;
  };
  scope.setTimeout = Object.assign(timeout, realTimeout) as unknown as typeof setTimeout;
  scope.setInterval = Object.assign(interval, realInterval) as unknown as typeof setInterval;
  scope.clearTimeout = ((handle?: unknown) => {
    if (handle != null) pendingTimers.delete(Number(handle));
    return realClearTimeout(handle as Parameters<typeof clearTimeout>[0]);
  }) as typeof clearTimeout;
  scope.clearInterval = ((handle?: unknown) => {
    if (handle != null) pendingTimers.delete(Number(handle));
    return realClearInterval(handle as Parameters<typeof clearInterval>[0]);
  }) as typeof clearInterval;
}

/// Clears the timers the file left pending; names them.
function drainTimers(): string[] {
  const drained: string[] = [];
  for (const { kind, handle, where } of pendingTimers.values()) {
    drained.push(`timer: a ${kind} from ${where} is still pending`);
    if (kind === "setInterval") realClearInterval(handle as Parameters<typeof clearInterval>[0]);
    else realClearTimeout(handle as Parameters<typeof clearTimeout>[0]);
  }
  pendingTimers.clear();
  return drained;
}

type Listening = {
  type: string;
  listener: unknown;
  capture: boolean;
  where: string;
  /// Added while the file's imports loaded: a module's own listener for the page's life.
  atLoad: boolean;
  fired?: () => void;
};
const listening: Listening[] = [];

function captureOf(options: unknown): boolean {
  return typeof options === "boolean" ? options : !!(options as { capture?: boolean } | undefined)?.capture;
}

/// Records listeners added to globalThis while a file runs (a file's own jsdom window and document
/// go away with it; globalThis does not).
function wrapGlobalListeners(): void {
  const target = globalThis as unknown as {
    addEventListener?: (...args: unknown[]) => void;
    removeEventListener?: (...args: unknown[]) => void;
  };
  const add = target.addEventListener;
  const remove = target.removeEventListener;
  if (typeof add !== "function" || typeof remove !== "function") return;
  const forget = (entry: Listening) => {
    const at = listening.indexOf(entry);
    if (at >= 0) listening.splice(at, 1);
  };
  target.addEventListener = function (this: unknown, type: unknown, listener: unknown, options?: unknown) {
    const settings = typeof options === "object" && options !== null ? (options as AddEventListenerOptions) : {};
    const capture = captureOf(options);
    const known = listening.some(
      (entry) => entry.type === String(type) && entry.listener === listener && entry.capture === capture,
    );
    if (listener && !known && !settings.signal?.aborted) {
      const entry: Listening = {
        type: String(type),
        listener,
        capture,
        where: loadingImports ? timerSite() : callerFrame(),
        atLoad: loadingImports,
      };
      listening.push(entry);
      // A `once` listener is gone after it fires: it counts until then, or until it is removed.
      if (settings.once) {
        entry.fired = () => forget(entry);
        add.call(this, type, entry.fired, { capture, once: true });
      }
      // A listener added with a signal is removed when the signal aborts.
      settings.signal?.addEventListener("abort", () => forget(entry), { once: true });
    }
    return add.call(this, type, listener, options);
  };
  target.removeEventListener = function (this: unknown, type: unknown, listener: unknown, options?: unknown) {
    const capture = captureOf(options);
    const at = listening.findIndex(
      (entry) => entry.type === String(type) && entry.listener === listener && entry.capture === capture,
    );
    if (at >= 0) {
      const [entry] = listening.splice(at, 1);
      if (entry.fired) remove.call(this, type, entry.fired, { capture });
    }
    return remove.call(this, type, listener, options);
  };
}

type FileStart = {
  path: string | undefined;
  globals: Map<string, PropertyDescriptor | undefined>;
  documents: Map<object, Map<PropertyKey, PropertyDescriptor>>;
};
let fileStart: FileStart | undefined;

function sameDescriptor(a: PropertyDescriptor | undefined, b: PropertyDescriptor | undefined): boolean {
  if (!a || !b) return a === b;
  return Object.is(a.value, b.value) && a.get === b.get && a.set === b.set;
}

function ownDescriptors(target: object): Map<PropertyKey, PropertyDescriptor> {
  return new Map(Reflect.ownKeys(target).map((key) => [key, Object.getOwnPropertyDescriptor(target, key)!]));
}

function globalKeys(): string[] {
  return Reflect.ownKeys(globalThis).filter((key): key is string => typeof key === "string");
}

/// The documents a later file could reach: the global one, and the one under the global window.
function globalDocuments(): object[] {
  const scope = globalThis as { document?: object; window?: { document?: object } };
  return [scope.document, scope.window?.document].filter((doc): doc is object => !!doc && typeof doc === "object");
}

/// Starts a checked file: what it registers from here on is its own. Called when bun loads the file
/// (before its imports) and again from the file's first line, which keeps the first start.
/// Between a checked file's load and its first line: what runs now is its imports loading.
let loadingImports = false;

function startFile(path?: string, atLoad = false): void {
  if (!atLoad) loadingImports = false;
  if (path !== undefined && fileStart?.path === path) return;
  loadingImports = atLoad;
  fileStart = {
    path,
    globals: new Map(globalKeys().map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)])),
    documents: new Map(globalDocuments().map((doc) => [doc, ownDescriptors(doc)])),
  };
  listening.length = 0;
  pendingTimers.clear();
  mocked.clear();
}

function leakedGlobals(start: FileStart): string[] {
  const leaks: string[] = [];
  const now = new Set(globalKeys());
  for (const key of now) {
    if (!start.globals.has(key)) leaks.push(`global: \`${key}\` was added and not removed`);
    else if (!sameDescriptor(start.globals.get(key), Object.getOwnPropertyDescriptor(globalThis, key)))
      leaks.push(`global: \`${key}\` was replaced and not restored`);
  }
  for (const key of start.globals.keys())
    if (!now.has(key)) leaks.push(`global: \`${key}\` was deleted and not restored`);
  // A document the file started with and that is still reachable: what the file defined on it stays.
  for (const doc of globalDocuments()) {
    const before = start.documents.get(doc);
    if (!before) continue;
    const props = ownDescriptors(doc);
    for (const [key, after] of props)
      if (!sameDescriptor(before.get(key), after))
        leaks.push(`global: document.${String(key)} was defined and not restored`);
    for (const key of before.keys())
      if (!props.has(key)) leaks.push(`global: document.${String(key)} was deleted and not restored`);
  }
  return leaks;
}

// --- The ratchet: each file's reset state and pending timers against leak-baseline.json. ---

/// leak-baseline.json: for each checked test file, the module state and timers it leaves behind
/// today (as drained above). A file may leave only items its baseline lists; scripts/leak-baseline.ts
/// can only lower it, so raising one is a hand edit that shows in review.
///
/// What a file leaves depends on what ran before it in the same process (a store an earlier file
/// loaded holds that file's loaded value), so an item the file leaves only after the other
/// agent-session files (`bun test src/agent-session/`) carries WITH_OTHERS. Run alone, as CI runs
/// each file, a file is held to its other items only.
// CMUX_TEST_LEAKS_BASELINE names another baseline file (test/leak-detector-probes.test.ts).
const BASELINE_PATH = process.env.CMUX_TEST_LEAKS_BASELINE || new URL("./leak-baseline.json", import.meta.url).pathname;
export const WITH_OTHERS = " (with other files)";
let baseline: Record<string, string[]> | undefined;
function baselineOf(name: string): string[] {
  baseline ??= existsSync(BASELINE_PATH)
    ? (JSON.parse(readFileSync(BASELINE_PATH, "utf8")) as Record<string, string[]>)
    : {};
  const items = baseline[name] ?? [];
  return alone()
    ? items.filter((item) => !item.endsWith(WITH_OTHERS))
    : items.map((item) => (item.endsWith(WITH_OTHERS) ? item.slice(0, -WITH_OTHERS.length) : item));
}

let aloneRun: boolean | undefined;
/// Whether this process runs one test file (`bun test ./a.test.ts`, as CI runs each file), not a
/// folder, a filter or several files.
function alone(): boolean {
  if (aloneRun !== undefined) return aloneRun;
  // From the command line itself (testOperands): under `bun test`, Bun.argv names only the file
  // running, so a run of several files looked like one file and a single file like several.
  const operands = testOperands() ?? [];
  aloneRun = operands.length === 1 && /\.test\.tsx?$/.test(operands[0]);
  return aloneRun;
}

const totals = { files: 0, leaks: 0, baseline: 0 };
let totalsHooked = false;

/// Prints the run's total once the process ends (one line per bun process: per file in CI, where
/// scripts/ci/run-webviews-tests.sh adds them up).
function hookTotals(): void {
  if (totalsHooked) return;
  totalsHooked = true;
  process.on("exit", () => {
    if (totals.files === 0 || mode === "off") return;
    writeSync(
      2,
      `agent-session leaks: ${totals.leaks} (baseline ${totals.baseline}) in ${totals.files} test files` +
        `${alone() ? "" : WITH_OTHERS}\n`,
    );
  });
}

function checkFile(path: string): void {
  // A listener a module adds while it loads stays for the module's life (it loads once per process),
  // so it counts with the module state below; one the file's own code added and left fails the file.
  const leaks = listening
    .filter((entry) => !entry.atLoad)
    .map(({ type, where }) => `listener: a "${type}" listener on globalThis was not removed (${where})`);
  const loadListeners = listening
    .filter((entry) => entry.atLoad)
    .map(({ type, where }) => `listener: a "${type}" listener on globalThis from ${where}, added as it loaded`);
  listening.length = 0;
  const drained = [...new Set([...drainModuleState(), ...drainTimers(), ...loadListeners])].sort();
  if (fileStart) leaks.push(...leakedGlobals(fileStart));
  leaks.push(...drainModuleMocks());
  fileStart = undefined;
  const name = shortPath(path);
  const allowed = baselineOf(name);
  hookTotals();
  totals.files += 1;
  totals.leaks += drained.length;
  totals.baseline += allowed.length;
  const record = process.env.CMUX_TEST_LEAKS_RECORD;
  if (record) appendFileSync(record, `${JSON.stringify({ file: name, alone: alone(), items: drained })}\n`);
  if (mode === "report") {
    const all = [...leaks, ...drained];
    if (all.length) console.error(`LEAK ${name} left state behind for the next test file:\n  ${all.join("\n  ")}`);
    return;
  }
  const failing = mode === "strict" ? [...leaks, ...drained] : leaks;
  if (mode !== "strict") {
    // By identity, never by count: a baseline leak fixed while a new one appears keeps the count,
    // and the new one must still fail the file, by name.
    const known = new Set(allowed);
    const added = drained.filter((item) => !known.has(item));
    if (added.length)
      failing.push(
        `${added.length} module state and timer leaks not in its baseline (test/support/leak-baseline.json):`,
        ...added.map((item) => `  ${item}`),
      );
    const left = new Set(drained);
    for (const item of allowed.filter((listed) => !left.has(listed)))
      console.error(
        `leak baseline: ${name} no longer leaves ${item}: lower the baseline (bun scripts/leak-baseline.ts ${name})`,
      );
  }
  if (failing.length === 0) return;
  throw new Error(
    `${name} left state behind for the next test file (test/support/leakDetector.ts):\n  ${failing.join("\n  ")}\n` +
      "Restore it in the file's own afterEach/afterAll: the store's reset, clearTimeout, removeEventListener, the global it replaced.",
  );
}

// --- Module mocks: bun's mock.module replaces a module for the rest of the process. ---

type Mocked = { real: Record<string, unknown>; restored: boolean; where: string };
const mocked = new Map<string, Mocked>();
let realMockModule: ((path: string, factory: () => unknown) => unknown) | undefined;

/// The file a stack frame's call came from (`at fn (/path/x.ts:1:2)` or `at /path/x.ts:1:2`).
function callerFile(): string | undefined {
  for (const line of (new Error().stack ?? "").split("\n").slice(2)) {
    if (line.includes("leakDetector")) continue;
    const match = /\(?((?:\/|[A-Za-z]:\\)[^()]+?):\d+:\d+\)?$/.exec(line.trim());
    if (match) return match[1];
  }
  return undefined;
}

function sameExports(a: Record<string, unknown>, b: unknown): boolean {
  if (!b || typeof b !== "object") return false;
  const keys = Object.keys(a);
  return (
    keys.length === Object.keys(b).length && keys.every((key) => Object.is(a[key], (b as Record<string, unknown>)[key]))
  );
}

/// Wraps mock.module: remembers each mocked module's real exports (loading it first), so the check
/// can tell a file that put them back from one that left the mock for every later file.
function wrapModuleMocks(): void {
  const target = mock as unknown as { module: (specifier: string, factory: () => unknown) => unknown };
  const original = target.module.bind(mock);
  realMockModule = original;
  target.module = (specifier: string, factory: () => unknown) => {
    const from = callerFile();
    if (!from || !CHECKED.test(from)) return original(specifier, factory);
    let path = specifier;
    try {
      path = Bun.resolveSync(specifier, from ? dirname(from) : process.cwd());
    } catch {
      return original(specifier, factory); // a bare name bun resolves its own way
    }
    let entry = mocked.get(path);
    if (!entry) {
      let real: Record<string, unknown> = {};
      try {
        real = { ...(createRequire(path)(path) as Record<string, unknown>) };
      } catch {
        // A module that cannot load here: nothing to put back.
      }
      entry = { real, restored: false, where: from ? shortPath(from) : "?" };
      mocked.set(path, entry);
    }
    const result = original(path, factory);
    entry.restored = sameExports(entry.real, factory());
    return result;
  };
}

/// Mocked modules the file left mocked; puts their real exports back.
function drainModuleMocks(): string[] {
  const leaks: string[] = [];
  for (const [path, { real, restored }] of mocked) {
    if (!restored) {
      leaks.push(
        `module mock: ${shortPath(path)} is still mocked (mock.module); put its real exports back in afterAll`,
      );
      realMockModule?.(path, () => real);
    }
  }
  mocked.clear();
  return leaks;
}

/// Installs the loader and the hooks before any test file loads.
// --- Which processes it runs in. ---

/// `bun test` flags that take a value, so the value is not read as a path or filter.
const VALUE_FLAGS = new Set([
  "-t",
  "--test-name-pattern",
  "--preload",
  "-r",
  "--reporter",
  "--reporter-outfile",
  "--coverage-dir",
  "--coverage-reporter",
  "--timeout",
  "--rerun-each",
  "--seed",
  "--max-concurrency",
  "--path-ignore-patterns",
  "--tsconfig-override",
  "--env-file",
  "--cwd",
  "-c",
  "--config",
]);

/// The paths and filters this `bun test` was given: Bun.argv and process.argv name only the file
/// running, so they come from the command line itself. Undefined when it cannot be read.
function testOperands(): string[] | undefined {
  let line: string[] | undefined;
  try {
    line = readFileSync("/proc/self/cmdline", "utf8").split("\0").filter(Boolean);
  } catch {
    try {
      line = execFileSync("ps", ["-o", "args=", "-p", String(process.pid)], { encoding: "utf8" })
        .trim()
        .split(/\s+/);
    } catch {
      return undefined;
    }
  }
  const at = line.indexOf("test");
  if (at < 0) return undefined;
  const operands: string[] = [];
  const args = line.slice(at + 1);
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (VALUE_FLAGS.has(arg)) index++;
    else if (!arg.startsWith("-")) operands.push(arg);
  }
  return operands;
}

// A file path, not the URL's: a checkout under a folder with a space reads "%20" in `pathname`.
const AGENT_SESSION = fileURLToPath(new URL("../../src/agent-session", import.meta.url));

/// Whether this `bun test` can reach a checked test file. One that runs only files outside the
/// checked folder (CI runs each file in its own process) gets no loader, timer or listener wrapper
/// at all: those files are not checked, and the loader alone changes when bun evaluates the modules
/// it serves (a test DOM's @pierre/diffs then registered its element without customElements).
function reachesCheckedFiles(): boolean {
  if (process.env.CMUX_TEST_LEAKS_SCOPE === "all") return true;
  const operands = testOperands();
  if (!operands || operands.length === 0) return true;
  return operands.some((operand) => {
    const path = resolve(operand);
    if (!existsSync(path)) return true; // a name filter: it may match a checked file
    if (!statSync(path).isDirectory()) return CHECKED.test(path);
    const folder = `${path.replace(/\/$/, "")}/`;
    return `${AGENT_SESSION}/`.startsWith(folder) || folder.startsWith(`${AGENT_SESSION}/`);
  });
}

export function installLeakDetector(): void {
  if (mode === "off" || !reachesCheckedFiles()) return;
  const scope = globalThis as Record<string, unknown>;
  scope.__cmuxModuleStart = moduleStart;
  scope.__cmuxModuleEnd = moduleEnd;
  scope.__cmuxStartFile = startFile;
  scope.__cmuxCheckFile = checkFile;
  wrapTimers();
  wrapGlobalListeners();
  wrapModuleMocks();
  Bun.plugin({
    name: "cmux-leak-detector",
    setup(build) {
      build.onLoad({ filter: /\.tsx?$/ }, ({ path }) => {
        const source = readFileSync(path, "utf8");
        const loader = path.endsWith("x") ? "tsx" : "ts";
        if (path.includes("/node_modules/")) return { contents: source, loader };
        if (/\.test\.tsx?$/.test(path)) {
          if (!CHECKED.test(path)) return { contents: source, loader };
          // A test file's static imports run before any line of its own, the injected start call
          // too, so the file starts here, when bun loads it and before it loads what it imports:
          // a timer or listener an import registers at load is the file's.
          startFile(path, true);
          return { contents: instrumentTest(path, source), loader };
        }
        if (WATCHED.test(path) && !/\.gallery\.tsx?$/.test(path))
          return { contents: instrumentModule(path, source), loader };
        return { contents: source, loader };
      });
    },
  });
}
