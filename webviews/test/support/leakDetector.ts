// Cross-file leak detector for `bun test` (test/preload.ts installs it).
//
// bun runs every test file in one process with one module cache, so whatever a file leaves behind is
// the next file's starting state: a store it filled, a timer still pending, a listener on a shared
// global, a global it installed and never restored. Each such file passes alone and the folder
// fails whole (AllChatsList.test.tsx left device chats that NewTabScreen.test.tsx then drew). After
// every checked test file (CHECKED below) this file looks at what the file left behind:
//
// - Module state. A loader hook registers every top-level `let` binding and every top-level
//   `new Map` / `new Set` of every source module under src/agent-session in one registry, with the
//   value it held when the module finished loading (a change one module's load makes to another's
//   state counts as loaded too: a registry other modules fill as they load). No module opts in, so
//   a store is in the registry the moment a test loads it. After each file the registry is drained:
//   every binding and collection is put back to its loaded value, so the next file starts on the
//   state a fresh process would give it.
// - Timers: a global setTimeout/setInterval the file started that is still pending is cleared, so it
//   cannot fire into the next file.
// - Listeners: a listener the file added to globalThis and did not remove fails the file.
// - Globals: a globalThis key the file added, replaced or deleted (window, document, HTMLElement,
//   localStorage, ...) and did not restore fails the file, and so does a property it defined on a
//   global document (Object.defineProperty(document, ...)) that outlives the file.
// - Module mocks: bun's mock.module replaces a module for every later file too. A module the file
//   mocked and did not mock back to its real exports fails the file (and is put back).
//
// Failures name what was left and where. Module state and timers are a ratchet, since most files
// leave a cache or counter behind today: test/support/leak-baseline.json lists what each file leaves,
// and a file fails only when it leaves more than its baseline, naming the new items. A file that
// leaves fewer prints a line asking to lower its baseline (`bun scripts/leak-baseline.ts FILE`, which
// can only lower counts; raising one is a hand edit to the JSON). Each process prints its total
// (`agent-session leaks: N (baseline B) in F test files`); the drain gives the next file a clean
// start either way. `CMUX_TEST_LEAKS=report` lists every leak and fails nothing,
// `CMUX_TEST_LEAKS=strict` fails every leak, `CMUX_TEST_LEAKS=off` turns the detector off.
// `CMUX_TEST_LEAKS_RECORD=FILE` appends each file's items as JSON lines (for the baseline script).
// `CMUX_TEST_LEAKS_SCOPE=all` checks every test file, not only src/agent-session's.
import { mock } from "bun:test";
import { appendFileSync, existsSync, readFileSync, writeSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname } from "node:path";

const mode = process.env.CMUX_TEST_LEAKS ?? "on";
/// Source modules whose top-level state is registered and drained.
const WATCHED = /\/src\/agent-session\/.*\.tsx?$/;
/// Test files checked after they run.
const CHECKED = process.env.CMUX_TEST_LEAKS_SCOPE === "all" ? /\.test\.tsx?$/ : /\/src\/agent-session\/.*\.test\.tsx?$/;

type Binding = { name: string; get: () => unknown; set: (value: unknown) => void };
type Collection = { name: string; get: () => unknown };
type Entries = [unknown, unknown][];
type Tracked =
  | { kind: "binding"; path: string; binding: Binding; loaded: unknown }
  | { kind: "collection"; path: string; name: string; value: Map<unknown, unknown> | Set<unknown>; loaded: Entries };

const tracked: Tracked[] = [];

function entriesOf(value: Map<unknown, unknown> | Set<unknown>): Entries {
  return value instanceof Map ? [...value.entries()] : [...value].map((item) => [item, item]);
}

function sameEntries(a: Entries, b: Entries): boolean {
  if (a.length !== b.length) return false;
  const byKey = new Map(a);
  return b.every(([key, value]) => byKey.has(key) && Object.is(byKey.get(key), value));
}

function current(item: Tracked): unknown {
  return item.kind === "binding" ? item.binding.get() : entriesOf(item.value);
}

function same(item: Tracked, a: unknown, b: unknown): boolean {
  return item.kind === "binding" ? Object.is(a, b) : sameEntries(a as Entries, b as Entries);
}

/// Snapshots taken when a watched module starts loading, one per module still loading.
const loading: unknown[][] = [];

/// Prepended to every watched module: remembers the registry's state as the module starts.
function moduleStart(): void {
  loading.push(tracked.map(current));
}

/// Appended to every watched module. A change the module's own load made to state already in the
/// registry is part of the loaded state (a module that registers itself in another's map), not a
/// leak; then the module's own state joins the registry as loaded.
function moduleEnd(path: string, bindings: Binding[], collections: Collection[]): void {
  const before = loading.pop();
  if (before)
    before.forEach((value, index) => {
      const item = tracked[index];
      const now = current(item);
      if (!same(item, value, now)) item.loaded = now;
    });
  for (const binding of bindings) {
    try {
      tracked.push({ kind: "binding", path, binding, loaded: binding.get() });
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
      if (Object.is(item.binding.get(), item.loaded)) continue;
      drained.push(`module state: ${shortPath(item.path)} \`${item.binding.name}\` is still set`);
      item.binding.set(item.loaded);
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
export function topLevelState(source: string): { lets: string[]; collections: string[] } {
  const lets = [...source.matchAll(/^(?:export )?let ([A-Za-z_$][\w$]*)/gm)].map((match) => match[1]);
  const collections = [
    ...source.matchAll(/^(?:export )?const ([A-Za-z_$][\w$]*)(?:\s*:[^=\n]+)?\s*=\s*new (?:Map|Set)\b/gm),
  ].map((match) => match[1]);
  return { lets, collections };
}

function instrumentModule(path: string, source: string): string {
  const { lets, collections } = topLevelState(source);
  const bindings = lets
    .map((name) => `{ name: ${JSON.stringify(name)}, get: () => ${name}, set: (__v: any) => { ${name} = __v; } }`)
    .join(", ");
  const colls = collections.map((name) => `{ name: ${JSON.stringify(name)}, get: () => ${name} }`).join(", ");
  return (
    `(globalThis as any).__cmuxModuleStart?.();\n${source}\n` +
    `;(globalThis as any).__cmuxModuleEnd?.(${JSON.stringify(path)}, [${bindings}], [${colls}]);\n`
  );
}

function instrumentTest(source: string): string {
  return (
    `(globalThis as any).__cmuxStartFile?.();\n${source}\n` +
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
    .filter((line) => line && !line.includes("leakDetector") && !line.includes("native:") && !/\(native\)$/.test(line));
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

type Listening = { type: string; listener: unknown; capture: boolean; where: string };
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
  target.addEventListener = function (this: unknown, type: unknown, listener: unknown, options?: unknown) {
    const once = typeof options === "object" && options !== null && (options as { once?: boolean }).once;
    if (listener && !once)
      listening.push({ type: String(type), listener, capture: captureOf(options), where: callerFrame() });
    return add.call(this, type, listener, options);
  };
  target.removeEventListener = function (this: unknown, type: unknown, listener: unknown, options?: unknown) {
    const capture = captureOf(options);
    const at = listening.findIndex(
      (entry) => entry.type === String(type) && entry.listener === listener && entry.capture === capture,
    );
    if (at >= 0) listening.splice(at, 1);
    return remove.call(this, type, listener, options);
  };
}

type FileStart = {
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

function startFile(): void {
  fileStart = {
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
/// today (as drained above). A file may leave no more than its baseline; scripts/leak-baseline.ts
/// can only lower it, so raising one is a hand edit that shows in review.
const BASELINE_PATH = new URL("./leak-baseline.json", import.meta.url).pathname;
let baseline: Record<string, string[]> | undefined;
function baselineOf(name: string): string[] {
  baseline ??= existsSync(BASELINE_PATH) ? (JSON.parse(readFileSync(BASELINE_PATH, "utf8")) as Record<string, string[]>) : {};
  return baseline[name] ?? [];
}
const totals = { files: 0, leaks: 0, baseline: 0 };
let totalsHooked = false;

/// Prints the run's total once the process ends (one line per bun process: per file in CI).
function hookTotals(): void {
  if (totalsHooked) return;
  totalsHooked = true;
  process.on("exit", () => {
    if (totals.files === 0 || mode === "off") return;
    writeSync(2, `agent-session leaks: ${totals.leaks} (baseline ${totals.baseline}) in ${totals.files} test files\n`);
  });
}

function checkFile(path: string): void {
  const drained = [...new Set([...drainModuleState(), ...drainTimers()])].sort();
  const leaks = listening.map(
    ({ type, where }) => `listener: a "${type}" listener on globalThis was not removed (${where})`,
  );
  listening.length = 0;
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
  if (record) appendFileSync(record, `${JSON.stringify({ file: name, items: drained })}\n`);
  if (mode === "report") {
    const all = [...leaks, ...drained];
    if (all.length) console.error(`LEAK ${name} left state behind for the next test file:\n  ${all.join("\n  ")}`);
    return;
  }
  const failing = mode === "strict" ? [...leaks, ...drained] : leaks;
  if (mode !== "strict") {
    if (drained.length > allowed.length) {
      const known = new Set(allowed);
      failing.push(
        `${drained.length} module state and timer leaks, baseline ${allowed.length} (test/support/leak-baseline.json); new:`,
        ...drained.filter((item) => !known.has(item)).map((item) => `  ${item}`),
      );
    } else if (drained.length < allowed.length)
      console.error(
        `leak baseline: ${name} leaves ${drained.length}, below its baseline ${allowed.length}: lower the baseline to ${drained.length} (bun scripts/leak-baseline.ts ${name})`,
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
export function installLeakDetector(): void {
  if (mode === "off") return;
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
        if (/\.test\.tsx?$/.test(path))
          return { contents: CHECKED.test(path) ? instrumentTest(source) : source, loader };
        if (WATCHED.test(path) && !/\.gallery\.tsx?$/.test(path))
          return { contents: instrumentModule(path, source), loader };
        return { contents: source, loader };
      });
    },
  });
}
