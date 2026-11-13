// l10n-allow-file: generated chats and diagnostics for a stress harness, not shipped UI.
// Synthetic growth harness for the pane's state layer (the acpmux direct client: session list, transcript, their
// maps, caches and timers), no pixels. Leo, 2026-11-10: "synthetically just break it fast and repeatedly ... under
// constraint, under load, under degenerate cases" and "Anything that grows the RAM ... for no reason. It gets fixed."
// So: a fake daemon that holds thousands of sessions and god sessions at once (bench/godFixture.ts), a virtual clock
// (time compressed: a day of timers fires in milliseconds), and per-operation samples of what the client retains
// after a full GC (heap bytes and objects through bun:jsc, and every Map, Set and array it reaches, by path). A
// scenario repeats one operation that should leave nothing behind (a session created, changed and closed; a chat
// reopened; a reconnect in the middle of a stream) and fits a line over the samples after warm-up: any slope over the
// stated noise band fails. Used by test/state-growth.test.ts (small sizes, every PR) and bench/state-growth.bench.ts
// (small and god side by side; perf-cron.py's web-ui-growth part).
/// <reference types="bun" />
import { heapStats } from "bun:jsc";
import { AcpmuxDirectClient, type EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { godLog, type GodOptions, type Scale } from "./godFixture";
import { slope, type ReplayLog } from "./replayLogs";

// ---------- virtual clock ----------
type Timer = { id: number; at: number; run: () => void; every?: number };

/// Replaces setTimeout, setInterval, their clears and Date.now with a clock that only `advance` moves, so an hour of
/// the client's quiet watches, reconnect backoffs and retries runs in a few milliseconds. `live` counts the timers
/// still pending: a growth sample, since a timer that is armed per operation and never cleared is a leak too.
export class VirtualClock {
  now = Date.UTC(2026, 10, 10, 8, 0, 0);
  private timers = new Map<number, Timer>();
  private nextId = 1;
  /// What the client's timers threw: a scenario with any fails (a throw in a timer is a crash in the app).
  errors: string[] = [];
  private saved: Record<string, unknown> = {};

  install(): this {
    const scope = globalThis as Record<string, any>;
    for (const key of ["setTimeout", "clearTimeout", "setInterval", "clearInterval"]) this.saved[key] = scope[key];
    this.saved.now = Date.now;
    const add = (run: unknown, delay: unknown, every: boolean, args: unknown[]) => {
      const id = this.nextId++;
      const ms = Math.max(0, Number(delay) || 0);
      const call = typeof run === "function" ? () => (run as (...a: unknown[]) => void)(...args) : () => {};
      this.timers.set(id, { id, at: this.now + ms, run: call, ...(every ? { every: Math.max(1, ms) } : {}) });
      return id;
    };
    const clear = (id: unknown) => void this.timers.delete(Number(id));
    scope.setTimeout = (run: unknown, delay?: unknown, ...args: unknown[]) => add(run, delay, false, args);
    scope.setInterval = (run: unknown, delay?: unknown, ...args: unknown[]) => add(run, delay, true, args);
    scope.clearTimeout = clear;
    scope.clearInterval = clear;
    Date.now = () => this.now;
    return this;
  }

  uninstall(): void {
    const scope = globalThis as Record<string, any>;
    for (const key of ["setTimeout", "clearTimeout", "setInterval", "clearInterval"]) scope[key] = this.saved[key];
    Date.now = this.saved.now as () => number;
  }

  get live(): number {
    return this.timers.size;
  }

  /// Moves the clock `ms` forward, firing each due timer in time order and letting its promises settle.
  async advance(ms: number): Promise<void> {
    const end = this.now + ms;
    for (;;) {
      await settle();
      let next: Timer | undefined;
      for (const timer of this.timers.values()) if (timer.at <= end && (!next || timer.at < next.at)) next = timer;
      if (!next) break;
      this.now = Math.max(this.now, next.at);
      if (next.every) next.at += next.every;
      else this.timers.delete(next.id);
      try {
        next.run();
      } catch (error) {
        // The clock goes on, as the page's would; the scenario reports it.
        if (this.errors.length < 20)
          this.errors.push(error instanceof Error ? `${error.name}: ${error.message}` : String(error));
      }
    }
    this.now = end;
    await settle();
  }
}

/// Lets queued microtasks (the fake daemon's replies, their continuations) run out.
export async function settle(rounds = 30): Promise<void> {
  for (let round = 0; round < rounds; round++) await Promise.resolve();
}

// ---------- fake daemon ----------
/// `maxBytes` as acpmux pages it: the records within the byte budget (at least one), counted from the end a read
/// starts at (the newest for an attach or a page before a seq).
function byteCap(events: EventRecord[], maxBytes: unknown, newestFirst: boolean): EventRecord[] {
  if (typeof maxBytes !== "number") return events;
  let bytes = 0;
  let take = 0;
  for (let index = 0; index < events.length; index++) {
    bytes += JSON.stringify(events[newestFirst ? events.length - 1 - index : index]).length;
    if (take > 0 && bytes > maxBytes) break;
    take += 1;
  }
  return newestFirst ? events.slice(events.length - take) : events.slice(0, take);
}

export type FakeSession = { summary: Record<string, any>; history: EventRecord[] };

/// A log of `scale`'s shape re-keyed to `sessionId`, records and all (godLog names its session `replay-<scale>`).
export function logFor(sessionId: string, scale: Scale, opts: GodOptions = {}): ReplayLog {
  const log = godLog(scale, opts);
  return {
    ...log,
    sessionId,
    summary: { ...log.summary, sessionId },
    events: log.events.map((event) => rekey(event, sessionId)),
  };
}

export function rekey(event: EventRecord, sessionId: string): EventRecord {
  const msg = event.msg as Record<string, any>;
  const params = msg?.params ? { ...msg.params, sessionId } : undefined;
  return { ...event, sessionId, msg: params ? { ...msg, params } : msg } as EventRecord;
}

/// acpmux over a fake socket, holding any number of sessions. The list pages as acpmux pages it (`limit`,
/// `nextCursor`), attach answers a session's newest records, `_acpmux/events` reads its stored ones, and the test
/// pushes live records and session changes or drops the socket. Replies come on microtasks, as a socket's would.
export class FakeDaemon {
  sessions = new Map<string, FakeSession>();
  socket?: any;
  opened = 0;
  /// The newest records each session's log keeps (all when unset). A scenario that streams for its whole run sets
  /// it, so the samples weigh the pane's copy of what streamed, not this fake's own log (a real acpmux keeps its log
  /// on disk, not in the pane's heap).
  keep?: number;

  add(summary: Record<string, any>, history: EventRecord[] = []): FakeSession {
    const session = { summary: { status: "idle", ...summary }, history };
    this.sessions.set(String(summary.sessionId), session);
    return session;
  }

  private list(): Record<string, any>[] {
    return [...this.sessions.values()]
      .map((session) => session.summary)
      .sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0) || (a.sessionId < b.sessionId ? -1 : 1));
  }

  private page(limit: unknown, cursor: unknown): Record<string, any> {
    const all = this.list();
    const from = typeof cursor === "string" ? Number(cursor) : 0;
    const size = typeof limit === "number" ? limit : all.length;
    const sessions = all.slice(from, from + size);
    return { sessions, ...(from + size < all.length ? { nextCursor: String(from + size) } : {}) };
  }

  answer(method: string, params: any): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return this.page(params?.limit, undefined);
      case "_acpmux/sessions":
        return this.page(params?.limit, params?.cursor);
      case "_acpmux/attach": {
        const session = this.sessions.get(params?.sessionId);
        if (!session) return null;
        const after = typeof params?.afterSeq === "number" ? params.afterSeq : undefined;
        const limit = typeof params?.limit === "number" ? params.limit : 400;
        const events =
          after === undefined
            ? byteCap(session.history.slice(-limit), params?.maxBytes, true)
            : session.history.filter((e) => e.seq > after);
        const lastSeq = session.history.at(-1)?.seq ?? 0;
        // Whether older records are left, for an attach that read the newest (one after a seq says nothing).
        if (after !== undefined) return { session: session.summary, lastSeq, events };
        return { session: session.summary, lastSeq, events, hasMore: events.length < session.history.length };
      }
      case "_acpmux/events": {
        const session = this.sessions.get(params?.sessionId);
        const history = session?.history ?? [];
        const before = params?.beforeSeq ?? Infinity;
        const after = params?.afterSeq ?? 0;
        const limit = typeof params?.limit === "number" ? params.limit : 5000;
        let events = history.filter((event) => event.seq > after && event.seq < before);
        const newestFirst = params?.beforeSeq !== undefined;
        let more = events.length > limit;
        events = newestFirst ? events.slice(-limit) : events.slice(0, limit);
        const capped = byteCap(events, params?.maxBytes, newestFirst);
        if (capped.length < events.length) more = true;
        events = capped;
        return { events, hasMore: more, more, lastSeq: history.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  }

  open = (): WebSocket => {
    this.opened += 1;
    const socket: any = {
      readyState: 0,
      send: (raw: string) => {
        if (socket.readyState !== 1) return;
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() => {
          if (socket.readyState !== 1) return;
          socket.onmessage?.({
            data: JSON.stringify({
              jsonrpc: "2.0",
              id: message.id,
              result: this.answer(message.method, message.params),
            }),
          });
        });
      },
      close: () => {
        socket.readyState = 3;
      },
    };
    this.socket = socket;
    queueMicrotask(() => {
      socket.readyState = 1;
      socket.onopen?.();
    });
    return socket as WebSocket;
  };

  private send(method: string, params: unknown): void {
    if (this.socket?.readyState === 1)
      this.socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  }

  /// Records `events` to their session and sends each live (unless `deliver` is false: the daemon logged it but
  /// this connection lost it, as acpmux drops a slow client's frames).
  push(events: EventRecord[], deliver = true): void {
    for (const event of events) {
      const history = event.sessionId === undefined ? undefined : this.sessions.get(event.sessionId)?.history;
      history?.push(event);
      if (history && this.keep !== undefined) while (history.length > this.keep) history.shift();
      if (deliver) this.send("_acpmux/event", event);
    }
  }

  /// Sends one record as is (a duplicate, or one out of order), without logging it again.
  deliver(event: EventRecord): void {
    this.send("_acpmux/event", event);
  }

  /// A session made or changed: logged in the list, and `_acpmux/session_changed` sent.
  changed(summary: Record<string, any>, kind = "updated"): void {
    const id = String(summary.sessionId);
    const held = this.sessions.get(id);
    if (held) held.summary = summary;
    else this.add(summary);
    this.send("_acpmux/session_changed", { kind, recordKind: kind, seq: 0, session: summary, sessionId: id });
  }

  /// A session closed for good (acpmux's purge): off the list, and the purge sent.
  purge(sessionId: string): void {
    this.sessions.delete(sessionId);
    this.send("_acpmux/session_changed", {
      kind: "purged",
      recordKind: "purged",
      seq: 0,
      session: { sessionId },
      sessionId,
    });
  }

  /// The connection drops under the client (a daemon restart, a network blip).
  drop(): void {
    const socket = this.socket;
    if (!socket) return;
    socket.readyState = 3;
    socket.onclose?.({ code: 1006, reason: "" });
  }
}

/// Opens a client on `daemon` showing `sessionId`, with the virtual clock already installed.
export async function connectClient(daemon: FakeDaemon, sessionId: string, clock: VirtualClock) {
  let rows: readonly AcpmuxRow[] = [];
  let snapshots = 0;
  const scope = globalThis as Record<string, any>;
  // The client times its reconnects with window.setTimeout; no DOM is needed for the rest.
  scope.window ??= globalThis;
  const connecting = AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId,
    },
    (snapshot: any) => {
      snapshots += 1;
      rows = snapshot.rows;
    },
    undefined,
    daemon.open,
  );
  // The open waits on replies and maybe a timer or two: run the clock until it settles.
  let client: AcpmuxDirectClient | undefined;
  void connecting.then((value) => (client = value));
  for (let step = 0; step < 200 && !client; step++) await clock.advance(10);
  if (!client) client = await connecting;
  await clock.advance(50);
  return { client, rows: () => rows, snapshots: () => snapshots };
}

// ---------- what the client retains ----------
/// Every Map, Set and array the client reaches within `depth` objects of it, by path, with its size: the
/// growth samples that name what grew. Shared objects count once, under the first path that reaches them.
export function retainedEntries(root: object, depth = 3): Map<string, number> {
  const out = new Map<string, number>();
  const seen = new Set<object>();
  const walk = (value: unknown, path: string, left: number) => {
    if (value === null || typeof value !== "object" || seen.has(value)) return;
    seen.add(value);
    // A path met more than once (the values of one Map) sums, so a cache of growing lists shows its growth.
    const add = (size: number) => out.set(path, (out.get(path) ?? 0) + size);
    if (value instanceof Map || value instanceof Set) {
      add(value.size);
      if (left > 0) {
        let index = 0;
        for (const item of value.values()) if (index++ < 64) walk(item, `${path}[]`, left - 1);
      }
      // A Map of its own kind (the client's OrderedRows) keeps its indexes in its own fields: walked too.
      if (Object.getPrototypeOf(value) === Map.prototype || Object.getPrototypeOf(value) === Set.prototype) return;
    } else if (Array.isArray(value)) {
      add(value.length);
      return;
    }
    if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer || value instanceof Promise) return;
    if (left <= 0) return;
    for (const key of Object.keys(value)) {
      let child: unknown;
      try {
        child = (value as Record<string, unknown>)[key];
      } catch {
        continue;
      }
      walk(child, path ? `${path}.${key}` : key, left - 1);
    }
  };
  walk(root, "", depth);
  return out;
}

export type Sample = {
  op: number;
  heapBytes: number;
  objects: number;
  entries: number;
  timers: number;
  byPath: Map<string, number>;
  /// Live cells by type (bun:jsc's objectTypeCounts): a failure names the types that grew, the stores aside.
  types: Record<string, number>;
};

/// One growth sample after a full collection.
export function sample(
  op: number,
  client: object,
  clock: VirtualClock,
  skip: (path: string) => boolean = () => false,
): Sample {
  clearWireLog(client as AcpmuxDirectClient);
  Bun.gc(true);
  const stats = heapStats();
  const byPath = retainedEntries(client);
  let entries = 0;
  for (const [path, size] of byPath) if (!skip(path)) entries += size;
  return {
    op,
    heapBytes: stats.heapSize,
    objects: stats.objectCount,
    entries,
    timers: clock.live,
    byPath,
    types: { ...stats.objectTypeCounts },
  };
}

const NO_PATHS: Map<string, number> = new Map();

/// Adds `next` to `samples`, keeping the path map and type counts only of the samples `judge` reads them from (the
/// first one it fits, `keep`, and the newest): every sample's detail held to the end was the harness's own growth,
/// about 4 KiB per operation at one sample in ten (measured on the Linux pool).
export function keepSample(samples: Sample[], next: Sample, keep: (index: number) => boolean): void {
  const previous = samples.at(-1);
  if (previous && !keep(samples.length - 1)) {
    previous.byPath = NO_PATHS;
    previous.types = {};
  }
  samples.push(next);
}

/// The noise bands a scenario's slopes are held to, per operation, after warm-up.
///   entries  0.05: an entry kept by one operation in twenty fails (a real leak keeps at least one per operation).
///   timers   0.05: the same for pending timers.
///   objects  objects per operation that are noise: the GC's own bookkeeping and interned strings.
///   heapBytes bytes per operation that are noise: allocator pages a full GC does not hand back.
export type Bands = { entries: number; timers: number; objects: number; heapBytes: number };
export const DEFAULT_BANDS: Bands = { entries: 0.05, timers: 0.05, objects: 40, heapBytes: 4096 };

export type Growth = {
  scenario: string;
  scale: Scale;
  ops: number;
  ms: number;
  perOp: { heapBytes: number; objects: number; entries: number; timers: number };
  /// The bands the slopes were held to (with what the streamed records weigh, for a scenario that streams).
  bands: Bands;
  /// The paths whose size grew over the measured samples, with how much per operation.
  grew: [string, number][];
  failures: string[];
};

/// Fits each sample series after `warm` samples and names every slope above its band.
export function judge(
  scenario: string,
  scale: Scale,
  samples: Sample[],
  warm: number,
  ms: number,
  bands = DEFAULT_BANDS,
): Growth {
  const kept = samples.slice(warm);
  const fit = (pick: (each: Sample) => number) => slope(kept.map((each) => ({ x: each.op, y: pick(each) })));
  const perOp = {
    heapBytes: fit((each) => each.heapBytes),
    objects: fit((each) => each.objects),
    entries: fit((each) => each.entries),
    timers: fit((each) => each.timers),
  };
  const grew: [string, number][] = [];
  const first = kept[0]?.byPath ?? new Map();
  const last = kept.at(-1)?.byPath ?? new Map();
  const span = (kept.at(-1)?.op ?? 0) - (kept[0]?.op ?? 0) || 1;
  for (const [path, size] of last) {
    const before = first.get(path) ?? 0;
    if (size > before) grew.push([path, (size - before) / span]);
  }
  grew.sort((a, b) => b[1] - a[1]);
  const types: [string, number][] = [];
  const typesBefore = kept[0]?.types ?? {};
  for (const [type, count] of Object.entries(kept.at(-1)?.types ?? {})) {
    const rate = (count - (typesBefore[type] ?? 0)) / span;
    if (rate >= 0.5) types.push([type, rate]);
  }
  types.sort((a, b) => b[1] - a[1]);
  const failures: string[] = [];
  for (const key of ["entries", "timers", "objects", "heapBytes"] as const)
    if (perOp[key] > bands[key])
      failures.push(`${scenario}/${scale}: ${key} grow ${perOp[key].toFixed(2)} per op (band ${bands[key]})`);
  if (failures.length && grew.length)
    failures.push(
      `grew: ${grew
        .slice(0, 6)
        .map(([path, rate]) => `${path} +${rate.toFixed(2)}/op`)
        .join(", ")}`,
    );
  if (failures.length && types.length)
    failures.push(
      `cells: ${types
        .slice(0, 6)
        .map(([type, rate]) => `${type} +${rate.toFixed(1)}/op`)
        .join(", ")}`,
    );
  return { scenario, scale, ops: kept.at(-1)?.op ?? 0, ms, perOp, bands, grew, failures };
}

// ---------- scenarios ----------
export type ScenarioOptions = { scale: Scale; ops?: number; every?: number; warm?: number; bands?: Partial<Bands> };

/// The sizes each scale runs at: small is an ordinary user's app, god a heavy user's (thousands of chats, the
/// god session's degenerate tail: MB tool outputs, subagents five deep, screenshots).
export const SIZES = {
  small: { sessions: 40, reopenChats: 24, chunk: 64 },
  god: { sessions: 3000, reopenChats: 24, chunk: 4096 },
} as const;

/// The god session's tail as an attach reads it: the last few hundred records hold MB outputs, a five-deep
/// subagent chain and screenshots, so each reopen of it pays for all of them.
export const GOD_TAIL: GodOptions = { turns: 60, mbOutputs: [1, 2], depth: 5, chainEvery: 20, imageEvery: 10 };
const tailOptions = (scale: Scale): GodOptions => (scale === "god" ? GOD_TAIL : { turns: 30 });

const summaryOf = (sessionId: string, at: number, extra: Record<string, unknown> = {}) => ({
  sessionId,
  cwd: `/home/dev/project-${sessionId.length % 7}`,
  title: `Chat ${sessionId}`,
  harness: "claude",
  status: "idle",
  updatedAt: at,
  activityAt: at,
  createdAt: at,
  turnCount: 1,
  ...extra,
});

type Run = { daemon: FakeDaemon; clock: VirtualClock; client: AcpmuxDirectClient; rows: () => readonly AcpmuxRow[] };

async function boot(scale: Scale, chats: number): Promise<Run> {
  const clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  const shown = "chat-shown";
  const log = logFor(shown, scale, tailOptions(scale));
  daemon.add(summaryOf(shown, clock.now), log.events);
  for (let index = 0; index < SIZES[scale].sessions; index++)
    daemon.add(summaryOf(`bg-${index}`, clock.now - index * 60_000, { preview: `Reply ${index}` }));
  for (let index = 0; index < chats; index++) {
    const id = `chat-${index}`;
    daemon.add(summaryOf(id, clock.now - index), logFor(id, scale, tailOptions(scale)).events);
  }
  const { client, rows } = await connectClient(daemon, shown, clock);
  return { daemon, clock, client, rows };
}

/// The wire log (wire.ts, the ACP inspector's ring) is bounded by design (MAX_ENTRIES entries, MAX_TEXT_CHARS of
/// text), but what it holds shifts with the size of the frames that came last: a few attach replies in place of many
/// small frames moves the heap by megabytes either way, far past any band. Each sample clears it first, so it never
/// reads as growth or as shrinkage; its own bound is test/acp-wire-log-retention.test.ts's and wire.ts's tests.
function clearWireLog(client: AcpmuxDirectClient): void {
  (client as unknown as { wire: { clear(): void } }).wire.clear();
}

async function measure(
  name: string,
  options: ScenarioOptions,
  run: Run,
  op: (index: number) => Promise<void>,
  skip?: (path: string) => boolean,
  expected?: { objects: number; heapBytes: number },
): Promise<Growth> {
  const every = options.every ?? 10;
  const warm = options.warm ?? 3;
  // At least five samples after warm-up, whatever OPS asked for: fewer fit no line.
  const ops = Math.max(options.ops ?? 120, (warm + 5) * every);
  const samples: Sample[] = [];
  const started = performance.now();
  try {
    for (let index = 1; index <= ops; index++) {
      await op(index);
      if (index % every === 0) keepSample(samples, sample(index, run.client, run.clock, skip), (at) => at === warm);
    }
  } finally {
    run.client.close();
    run.clock.uninstall();
  }
  const bands = { ...DEFAULT_BANDS, ...options.bands };
  // A scenario whose operation streams records into the transcript grows the transcript's own log by them, by
  // design: its bands add what those records weigh (`expected`: their bytes measured, their cells counted), never a
  // round allowance.
  for (const key of ["objects", "heapBytes"] as const) bands[key] += expected?.[key] ?? 0;
  const growth = judge(name, options.scale, samples, warm, performance.now() - started, bands);
  if (run.clock.errors.length) growth.failures.push(`${name}: a timer threw: ${run.clock.errors.join("; ")}`);
  return growth;
}

/// Sessions churn: one is made, changes three times (it runs, says something, goes idle), another listed chat changes,
/// and the new one closes for good. Nothing of it should stay.
export async function sessionChurn(options: ScenarioOptions): Promise<Growth> {
  const run = await boot(options.scale, 0);
  const { daemon, clock } = run;
  const total = SIZES[options.scale].sessions;
  return measure("session-churn", options, run, async (index) => {
    const id = `churn-${index}`;
    const at = clock.now;
    daemon.changed(summaryOf(id, at), "created");
    daemon.changed(summaryOf(id, at + 1, { status: "running", lane: { state: "working" } }));
    daemon.changed(summaryOf(id, at + 2, { status: "running", preview: `Working on ${index}` }));
    daemon.changed(summaryOf(id, at + 3, { status: "idle", preview: `Done ${index}`, unread: true }));
    // One of eight listed chats changes too: few enough that warm-up has read each ahead once (the read ahead keeps
    // one entry per listed chat it read, bounded by the list, which a ring over all of them would count as growth).
    const other = `bg-${index % Math.min(total, 8)}`;
    daemon.changed(summaryOf(other, at + 4, { preview: `Reply ${index}` }));
    daemon.purge(id);
    await clock.advance(250);
  });
}

/// Chats reopen: the pane moves to the next of a ring of chats (each a god tail at god scale), round and round.
/// Once every chat was shown once, each open holds what the one before held: caches are full, nothing else stays.
export async function chatReopen(options: ScenarioOptions): Promise<Growth> {
  const chats = SIZES[options.scale].reopenChats;
  const run = await boot(options.scale, chats);
  const { client, clock } = run;
  let missed = 0;
  return measure(
    "chat-reopen",
    { warm: Math.ceil((chats * 2) / (options.every ?? 10)), ...options, ops: options.ops ?? chats * 6 },
    run,
    async (index) => {
      const id = `chat-${index % chats}`;
      const opening = client.select(id);
      await clock.advance(400);
      await opening.catch(() => undefined);
      await clock.advance(100);
      if (shownSession(client) !== id || run.rows().length === 0) missed += 1;
    },
  ).then((growth) => {
    if (missed) growth.failures.push(`chat-reopen: ${missed} opens did not show their chat`);
    return growth;
  });
}

const shownSession = (client: AcpmuxDirectClient) =>
  (client as unknown as { selectedSessionId?: string }).selectedSessionId;

/// Reconnects mid-stream: a reply streams into the shown chat, the socket drops in the middle of it, the pane
/// reconnects (its backoff run by the clock) and reads what it missed, and the reply streams on. The transcript's own
/// log (`events`) grows by the records streamed, by design; every other store must stay flat.
export async function reconnectMidStream(options: ScenarioOptions): Promise<Growth> {
  const run = await boot(options.scale, 0);
  const { daemon, clock, client } = run;
  const id = "chat-shown";
  daemon.keep = 64;
  let seq = daemon.sessions.get(id)!.history.at(-1)!.seq;
  const record = (kind: string, dir: string, msg: Record<string, unknown>): EventRecord =>
    ({ sessionId: id, seq: ++seq, at: clock.now, dir, kind, msg }) as EventRecord;
  daemon.push([record("user_message", "mux", { text: "Stream a long answer" }), record("turn_started", "mux", {})]);
  const chunk = "x".repeat(SIZES[options.scale].chunk);
  const say = (text: string) =>
    record("agent_message_chunk", "in", {
      method: "session/update",
      params: { sessionId: id, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
    });
  // Five records stream per operation (two before the drop, two while it is down, one after), and the reply's row
  // draws their text: its string grows by the five chunks (a rope cell each until it is read whole).
  const records = recordWeight(say(chunk), 5);
  const weight = { objects: records.objects + 5, heapBytes: records.heapBytes + 5 * chunk.length };
  seq -= 1;
  const growth = await measure(
    "reconnect-mid-stream",
    options,
    run,
    async () => {
      daemon.push([say(chunk), say(chunk)]);
      daemon.drop();
      // Records the dropped connection never saw: the reconnect's attach reads them.
      daemon.push([say(chunk), say(chunk)], false);
      await clock.advance(30_000);
      daemon.push([say(chunk)]);
      await clock.advance(100);
    },
    (path) => path === "events",
    weight,
  );
  // The scenario measures nothing unless each drop was followed by a fresh connection.
  if (daemon.opened < growth.ops)
    growth.failures.push(`reconnect-mid-stream: ${daemon.opened} connections for ${growth.ops} drops`);
  const held = (client as unknown as { events: EventRecord[] }).events.map((event) => event.seq);
  if (new Set(held).size !== held.length) growth.failures.push("reconnect-mid-stream: the held log has a record twice");
  if (held.at(-1) !== seq)
    growth.failures.push(`reconnect-mid-stream: the held log ends at ${held.at(-1)}, the daemon's at ${seq}`);
  return growth;
}

/// A shell call's output streams in through `tool_call_update`s, each carrying the whole output so far (ACP's
/// `content` replaces the call's), in one long turn. The call's row shows only the newest; what else stays per update?
export async function toolOutputStream(options: ScenarioOptions): Promise<Growth> {
  const run = await boot(options.scale, 0);
  const { daemon, clock } = run;
  const id = "chat-shown";
  daemon.keep = 64;
  let seq = daemon.sessions.get(id)!.history.at(-1)!.seq;
  const record = (kind: string, dir: string, msg: Record<string, unknown>): EventRecord =>
    ({ sessionId: id, seq: ++seq, at: clock.now, dir, kind, msg }) as EventRecord;
  const update = (fields: Record<string, unknown>) =>
    record(String(fields.sessionUpdate), "in", { method: "session/update", params: { sessionId: id, update: fields } });
  daemon.push([
    record("user_message", "mux", { text: "Run the suite" }),
    record("turn_started", "mux", {}),
    update({
      sessionUpdate: "tool_call",
      toolCallId: "stream-1",
      kind: "execute",
      title: "Run bun test",
      status: "in_progress",
      rawInput: { command: "bun test" },
    }),
  ]);
  const size = options.scale === "god" ? 256 * 1024 : 1024;
  const body = "y".repeat(size);
  const output = (index: number) =>
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: "stream-1",
      status: "in_progress",
      content: [{ type: "content", content: { type: "text", text: `${index}\n${body}` } }],
    });
  // Today the transcript's log (`events`) holds each update whole, the outputs it superseded too: one record's
  // weight per update is that log, and anything past it fails. (Holding only the newest output of a call is the
  // follow-up the PR names; this scenario then drops `expected` and holds the heap flat.)
  const weight = recordWeight(output(0), 1);
  seq -= 1;
  return measure(
    "tool-output-stream",
    options,
    run,
    async (index) => {
      daemon.push([output(index)]);
      await clock.advance(50);
    },
    (path) => path === "events",
    weight,
  );
}

/// What `count` records like `event` weigh once the client holds them: bytes measured (each parsed from its frame, as
/// the client parses it, and held), cells counted (every object, array and string in the parsed record; heapStats'
/// objectCount moves too little across 64 small records to measure). The growth a scenario that streams records into
/// the transcript expects per operation.
export function recordWeight(event: EventRecord, count: number): { objects: number; heapBytes: number } {
  const frame = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
  const copies = 64;
  Bun.gc(true);
  const before = heapStats();
  const held = Array.from({ length: copies }, () => JSON.parse(frame).params);
  Bun.gc(true);
  const after = heapStats();
  if (held.length !== copies) throw new Error("unreachable");
  const cells = (value: unknown): number =>
    typeof value === "string"
      ? 1
      : value && typeof value === "object"
        ? 1 + Object.values(value).reduce<number>((sum, item) => sum + cells(item), 0)
        : 0;
  return {
    objects: cells(held[0]) * count,
    heapBytes: (Math.max(0, after.heapSize - before.heapSize) / copies) * count,
  };
}

/// A day of one chat, replayed live in seconds: every record of a generated log (small: 300 turns over a working
/// day; god: 1,500 turns over a month with MB outputs, five-deep subagents and screenshots) arrives at its own time
/// on the virtual clock, so each quiet watch, stall check and repair read fires as it would. The transcript grows
/// by design here, so the check is its shape: pending timers stay flat, and what each turn adds (entries, objects,
/// bytes) in the day's second half stays within 25 % of what it added in the first half plus the noise band. A
/// store that costs more per turn the longer the chat gets fails.
export async function dayReplay(options: ScenarioOptions): Promise<Growth> {
  const clock = new VirtualClock().install();
  const daemon = new FakeDaemon();
  const id = "chat-day";
  const opts: GodOptions =
    options.scale === "god"
      ? { turns: 1500, days: 30, mbOutputs: [1, 2, 3, 4], depth: 5, chainEvery: 200, imageEvery: 50 }
      : {};
  const events = logFor(id, options.scale, opts).events;
  const opener = events.findIndex((event) => event.kind === "turn_result") + 1;
  clock.now = events[0]!.at;
  daemon.add(summaryOf(id, clock.now, { status: "running" }), events.slice(0, opener));
  for (let index = 0; index < SIZES[options.scale].sessions; index++)
    daemon.add(summaryOf(`bg-${index}`, clock.now - index * 60_000));
  const { client } = await connectClient(daemon, id, clock);
  const samples: Sample[] = [];
  const every = Math.max(1, Math.floor((options.ops ?? 0) / 20) || (options.scale === "god" ? 50 : 10));
  const started = performance.now();
  let turns = 0;
  // The halves judged below read the detail of samples 1 and the middle one (and the newest).
  const ends = events.slice(opener).filter((event) => event.kind === "turn_result").length;
  const middle = Math.floor(Math.floor(ends / every) / 2);
  try {
    for (const event of events.slice(opener)) {
      if (event.at > clock.now) await clock.advance(event.at - clock.now);
      daemon.push([event]);
      if (event.kind === "turn_result" && ++turns % every === 0) {
        await clock.advance(10);
        keepSample(samples, sample(turns, client, clock), (at) => at === 1 || at === middle);
      }
    }
  } finally {
    client.close();
    clock.uninstall();
  }
  const ms = performance.now() - started;
  const half = Math.floor(samples.length / 2);
  const first = judge("day-replay", options.scale, samples.slice(0, half + 1), 1, ms);
  const second = judge("day-replay", options.scale, samples.slice(half), 0, ms);
  const failures: string[] = [];
  if (second.perOp.timers > DEFAULT_BANDS.timers)
    failures.push(`day-replay/${options.scale}: timers grow ${second.perOp.timers.toFixed(2)} per turn`);
  // The day's bands: what a turn added in the first half, a quarter more, and the noise band.
  const bands: Bands = { ...DEFAULT_BANDS };
  for (const key of ["entries", "objects", "heapBytes"] as const) {
    const limit = Math.max(0, first.perOp[key]) * 1.25 + DEFAULT_BANDS[key];
    bands[key] = limit;
    if (second.perOp[key] > limit)
      failures.push(
        `day-replay/${options.scale}: ${key} per turn grew from ${first.perOp[key].toFixed(1)} to ` +
          `${second.perOp[key].toFixed(1)} over the day (limit ${limit.toFixed(1)})`,
      );
  }
  if (clock.errors.length) failures.push(`day-replay: a timer threw: ${clock.errors.join("; ")}`);
  if (failures.length && second.grew.length)
    failures.push(
      `grew: ${second.grew
        .slice(0, 6)
        .map(([path, rate]) => `${path} +${rate.toFixed(2)}/turn`)
        .join(", ")}`,
    );
  return { ...second, ops: turns, perOp: second.perOp, bands, failures };
}

export const SCENARIOS = { sessionChurn, chatReopen, reconnectMidStream, toolOutputStream, dayReplay } as const;
