// cmux.watch(name, params): a live, cached read of a signal source (schema/v2/signals.json,
// table in generated/signals.json). ABI.md, Signals, is the contract. In short:
// - one entry per (name, canonical params) per app: every reader shares one upstream read;
// - refcounted: the push subscriptions and the one timer exist only while a reader is mounted;
// - pushed sources re-read on their events (coalesced: one read in flight, at most one queued);
//   unpushed sources poll every staleAfterSeconds (or a reader's everySeconds), never faster
//   than pollFloorSeconds;
// - stale-while-revalidate: a re-read and a failed re-read keep the old value (status stale);
// - errors back off from the floor, doubling, to 15 minutes; refused reads are not retried.
// The entry table is the seam for a daemon-wide cache: the app-facing API does not change if the
// table moves behind host functions (ABI.md, Signals, next step).

import { callWith, CmuxError, HOST_OPS, log, setTimer, clearTimer, state, type CallOptions } from "./cmux.ts"
import { batch, effect, getOwner, onCleanup, runWithOwner, signal, untrack, type Read, type Write } from "./reactive.ts"
import { READERS } from "./signal-readers.ts"
import { SchemaValidator } from "../../tools/json-schema.ts"
import table from "../../generated/signals.json"

export type WatchStatus = "loading" | "fresh" | "stale" | "error"
export interface WatchState<T = unknown> {
  value: T | undefined
  status: WatchStatus
  error?: CmuxError
  updatedAt: number | null
}

interface SignalDef {
  docs: string
  scopes: string[]
  params: Record<string, unknown>
  read: { op: string } | { reader: string; ops: Array<{ op: string; scope: string }> }
  push: string[]
  pollFloorSeconds: number
  staleAfterSeconds: number
}

const SIGNALS = (table as unknown as { signals: Record<string, SignalDef> }).signals
const MAX_BACKOFF_MS = 15 * 60_000
/** Inactive entries kept for a quick remount; the oldest is dropped past this. */
const MAX_IDLE_ENTRIES = 32
/** Errors that a retry cannot fix: the person or the app has to act (grant, connect, fix params). */
const FINAL = new Set(["scope.missing", "operation.unsupported", "signal.unknown", "signal.params", "validation.invalid"])

interface Entry {
  key: string
  name: string
  def: SignalDef
  params: Record<string, unknown>
  value: [Read<unknown>, Write<unknown>]
  status: [Read<WatchStatus>, Write<WatchStatus>]
  error: [Read<CmuxError | undefined>, Write<CmuxError | undefined>]
  updatedAt: [Read<number | null>, Write<number | null>]
  /** Live readers: their everySeconds (undefined = the source's default). */
  readers: Map<number, number | undefined>
  subs: Array<() => void>
  timer: number | null
  inFlight: Promise<void> | null
  again: boolean
  queued: boolean
  failures: number
  lastUse: number
}

/** Reads and counters a test or a host can look at (cmux.watch is not instrumented otherwise). */
export const watchStats = { reads: 0, entries: () => entries.size }

const entries = new Map<string, Entry>()
let nextReader = 1
const validators = new Map<string, SchemaValidator>()

/** Canonical JSON: object keys sorted at every level, so {a,b} and {b,a} share one entry. */
function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>
    return `{${Object.keys(o).filter((k) => o[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(",")}}`
  }
  return JSON.stringify(v ?? null)
}

/** Keeps the old object wherever the new one is deep-equal, so unchanged rows emit no scene ops. */
function share(prev: unknown, next: unknown): unknown {
  if (Object.is(prev, next)) return prev
  if (Array.isArray(prev) && Array.isArray(next)) {
    let same = prev.length === next.length
    const out = next.map((n, i) => {
      const s = share(prev[i], n)
      if (s !== prev[i]) same = false
      return s
    })
    return same ? prev : out
  }
  if (prev && next && typeof prev === "object" && typeof next === "object" && !Array.isArray(prev) && !Array.isArray(next)) {
    const p = prev as Record<string, unknown>
    const n = next as Record<string, unknown>
    const keys = Object.keys(n)
    let same = keys.length === Object.keys(p).length
    const out: Record<string, unknown> = {}
    for (const k of keys) {
      out[k] = share(p[k], n[k])
      if (out[k] !== p[k] || !(k in p)) same = false
    }
    return same ? prev : out
  }
  return next
}

const asError = (e: unknown) => (e instanceof CmuxError ? e : new CmuxError("operation.failed", e instanceof Error ? e.message : String(e)))

function lookup(name: string, params: unknown): { def: SignalDef; params: Record<string, unknown> } {
  const def = typeof name === "string" ? SIGNALS[name] : undefined
  if (!def) throw new CmuxError("signal.unknown", `no signal source named ${String(name)}; sources: ${Object.keys(SIGNALS).sort().join(", ")}`, { signal: name })
  const p = (params ?? {}) as Record<string, unknown>
  let v = validators.get(name)
  if (!v) validators.set(name, (v = new SchemaValidator(def.params)))
  const errors = v.validate(p)
  if (errors.length) throw new CmuxError("signal.params", `${name}: ${errors.map((e) => `${e.path || "params"} ${e.message}`).join("; ")}`, { signal: name, errors })
  return { def, params: JSON.parse(canonical(p)) as Record<string, unknown> }
}

/** The ops a source reads that this app's grant allows (null: the host did not say, so all). */
function missingScope(def: SignalDef): CmuxError | null {
  if (!state.allowedOps) return null
  const ops = "op" in def.read ? [def.read.op] : def.read.ops.map((o) => o.op)
  if (ops.some((op) => HOST_OPS.has(op) || state.allowedOps!.has(op))) return null
  return new CmuxError("scope.missing", `this app needs one of ${def.scopes.join(", ")} to watch it`, { scopes: def.scopes }, false)
}

function entryFor(name: string, def: SignalDef, params: Record<string, unknown>): Entry {
  const key = `${name} ${canonical(params)}`
  let e = entries.get(key)
  if (e) return e
  e = {
    key,
    name,
    def,
    params,
    value: signal<unknown>(undefined),
    status: signal<WatchStatus>("loading"),
    error: signal<CmuxError | undefined>(undefined),
    updatedAt: signal<number | null>(null),
    readers: new Map(),
    subs: [],
    timer: null,
    inFlight: null,
    again: false,
    queued: false,
    failures: 0,
    lastUse: Date.now()
  }
  entries.set(key, e)
  return e
}

const snapshot = (e: Entry): WatchState => {
  const error = e.error[0]()
  const s: WatchState = { value: e.value[0](), status: e.status[0](), updatedAt: e.updatedAt[0]() }
  if (error) s.error = error
  return s
}

const active = (e: Entry) => e.readers.size > 0

/** The poll interval while unpushed: the shortest a reader asked for, never under the floor. */
function pollMs(e: Entry): number {
  let s = e.def.staleAfterSeconds
  for (const every of e.readers.values()) if (typeof every === "number" && every > 0) s = Math.min(s, every)
  return Math.max(e.def.pollFloorSeconds, s) * 1000
}

/** Arms the entry's one timer `ms` from now; a negative `ms` only clears it. */
function schedule(e: Entry, ms: number) {
  if (e.timer !== null) clearTimer(e.timer)
  e.timer = null
  if (!active(e) || ms < 0) return
  e.timer = runWithOwner(null, () =>
    setTimer(ms, false, () => {
      e.timer = null
      read(e)
    })
  )
}

/** After a read settles: the next poll, a backoff retry, or nothing (pushed and fine, or final). */
function next(e: Entry, error: CmuxError | null) {
  if (!active(e)) return
  if (error) {
    if (FINAL.has(error.code)) return schedule(e, -1)
    const floor = e.def.pollFloorSeconds * 1000
    return schedule(e, Math.min(MAX_BACKOFF_MS, floor * 2 ** Math.min(e.failures - 1, 20)))
  }
  if (e.def.push.length) return schedule(e, -1)
  schedule(e, pollMs(e))
}

function upstream(e: Entry): Promise<unknown> {
  const call = <T>(op: string, params: unknown) => callWith<T>(op, params, {} as CallOptions, undefined).then((r) => r.value)
  if ("op" in e.def.read) return call(e.def.read.op, e.params)
  const reader = READERS[e.def.read.reader]
  if (!reader) return Promise.reject(new CmuxError("signal.unknown", `this runtime has no reader ${e.def.read.reader}`))
  return reader(e.params, call)
}

function read(e: Entry): Promise<void> {
  if (e.inFlight) {
    e.again = true
    return e.inFlight
  }
  const scope = missingScope(e.def)
  if (scope) {
    batch(() => fail(e, scope))
    return Promise.resolve()
  }
  if (e.timer !== null) clearTimer(e.timer)
  e.timer = null
  watchStats.reads++
  if (e.value[0].peek() !== undefined) e.status[1]("stale")
  let settled: CmuxError | null = null
  const run = upstream(e).then(
    (v) =>
      batch(() => {
        e.value[1](() => share(e.value[0].peek(), v))
        e.status[1]("fresh")
        e.error[1](undefined)
        e.updatedAt[1](Date.now())
        e.failures = 0
      }),
    (err) => {
      settled = asError(err)
      batch(() => fail(e, settled!))
    }
  )
  // A reader effect that throws while the new value flushes must not wedge the entry in flight.
  e.inFlight = run.catch((err) => log("error", `watch ${e.name}: ${asError(err).message}`)).then(() => {
    e.inFlight = null
    if (e.again) {
      e.again = false
      return read(e)
    }
    next(e, settled)
  })
  return e.inFlight
}

function fail(e: Entry, error: CmuxError) {
  e.failures++
  e.error[1](error)
  e.status[1](e.value[0].peek() === undefined ? "error" : "stale")
  if (e.failures === 1) log("warn", `watch ${e.name}: ${error.code}: ${error.message}`)
}

/** A pushed event: one read for every event of this turn (and one queued behind a read in flight). */
function pushed(e: Entry) {
  if (e.queued) return
  e.queued = true
  Promise.resolve().then(() => {
    e.queued = false
    if (active(e)) read(e)
  })
}

function activate(e: Entry) {
  runWithOwner(null, () => {
    for (const stream of e.def.push) {
      try {
        const subId = state.native!.subscribe(stream, "{}")
        state.subscriptions.set(subId, () => pushed(e))
        e.subs.push(() => {
          if (state.subscriptions.delete(subId)) state.native?.unsubscribe(subId)
        })
      } catch (err) {
        log("warn", `watch ${e.name}: cannot subscribe to ${stream}: ${asError(err).message}`)
      }
    }
  })
  const age = e.updatedAt[0].peek() === null ? Infinity : Date.now() - e.updatedAt[0].peek()!
  // A pushed source missed its events while nobody watched; an unpushed one is good until stale.
  const due = e.value[0].peek() === undefined || e.def.push.length > 0 || age >= e.def.staleAfterSeconds * 1000 || e.status[0].peek() !== "fresh"
  if (due) read(e)
  else schedule(e, Math.max(e.def.pollFloorSeconds * 1000, pollMs(e) - age))
}

function deactivate(e: Entry) {
  for (const off of e.subs.splice(0)) off()
  if (e.timer !== null) clearTimer(e.timer)
  e.timer = null
  e.lastUse = Date.now()
  prune()
}

function prune() {
  const idle = [...entries.values()].filter((x) => !active(x)).sort((a, b) => a.lastUse - b.lastUse)
  for (const x of idle.slice(0, Math.max(0, idle.length - MAX_IDLE_ENTRIES))) if (!x.inFlight) entries.delete(x.key)
}

export type Watch<T = unknown> = Read<WatchState<T>> & {
  value: Read<T | undefined>
  status: Read<WatchStatus>
  error: Read<CmuxError | undefined>
  updatedAt: Read<number | null>
  refresh: () => Promise<WatchState<T>>
  dispose: () => void
}

/** Joins entry `e` as reader `id`; returns the release. */
function join(e: Entry, id: number, everySeconds: number | undefined): () => void {
  const first = !active(e)
  e.readers.set(id, everySeconds)
  if (first) activate(e)
  else if (everySeconds && !e.def.push.length && !e.inFlight && e.timer !== null && e.failures === 0) schedule(e, pollMs(e))
  let released = false
  return () => {
    if (released) return
    released = true
    e.readers.delete(id)
    if (!active(e)) deactivate(e)
    else if (!e.def.push.length && e.timer !== null && !e.inFlight && e.failures === 0) schedule(e, pollMs(e))
  }
}

/**
 * Starts (or joins) the watch of `name` for the current owner: the render or effect that calls it.
 * `params` may be a function: it is tracked, and when its answer changes the reader moves to the
 * new entry (a setting that changes what to read). Throws `signal.unknown` or `signal.params`;
 * a missing scope is the watch's error.
 */
export function watch<T = unknown>(name: string, params?: unknown, options: { everySeconds?: number } = {}): Watch<T> {
  const every = typeof options.everySeconds === "number" ? options.everySeconds : undefined
  const id = nextReader++
  const resolve = (p: unknown) => {
    const found = lookup(name, p)
    return entryFor(name, found.def, found.params)
  }
  const [current, setCurrent] = signal<Entry>(resolve(typeof params === "function" ? untrack(params as () => unknown) : params))
  let release = untrack(() => join(current.peek(), id, every))
  let disposed = false
  const dispose = () => {
    if (disposed) return
    disposed = true
    release()
  }
  if (typeof params === "function") {
    let first = true
    effect(() => {
      const p = (params as () => unknown)()
      if (first) {
        first = false
        return
      }
      untrack(() => {
        if (disposed) return
        let e: Entry
        try {
          e = resolve(p)
        } catch (err) {
          log("error", `watch ${name}: ${asError(err).message}`)
          return
        }
        if (e === current.peek()) return
        const old = release
        release = join(e, id, every)
        setCurrent(e)
        old()
      })
    })
  }
  if (getOwner()) onCleanup(dispose)
  const accessor = (() => snapshot(current())) as Watch<T>
  Object.assign(accessor, {
    peek: () => untracked(current.peek()),
    value: field(current, (e) => e.value[0]),
    status: field(current, (e) => e.status[0]),
    error: field(current, (e) => e.error[0]),
    updatedAt: field(current, (e) => e.updatedAt[0]),
    refresh: () => {
      const e = current.peek()
      return read(e).then(() => untracked(e) as WatchState<T>)
    },
    dispose
  })
  return accessor
}

/** One field of the current entry as a Read (tracks the entry switch and the field). */
function field<V>(current: Read<Entry>, pick: (e: Entry) => Read<V>): Read<V> {
  const r = (() => pick(current())()) as Read<V>
  ;(r as { peek: () => V }).peek = () => pick(current.peek()).peek()
  return r
}

const untracked = (e: Entry): WatchState => {
  const error = e.error[0].peek()
  const s: WatchState = { value: e.value[0].peek(), status: e.status[0].peek(), updatedAt: e.updatedAt[0].peek() }
  if (error) s.error = error
  return s
}

/** Re-reads (name, params) now, for a command; readers of the same entry see the result. */
watch.refresh = async (name: string, params?: unknown): Promise<WatchState> => {
  const found = lookup(name, params)
  const e = entryFor(name, found.def, found.params)
  await read(e)
  if (!active(e)) prune()
  return untracked(e)
}
