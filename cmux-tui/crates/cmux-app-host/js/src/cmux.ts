// The `cmux` global: every catalog op as `cmux.<family>.<verb>(params, options)`,
// plus events, live queries, storage, egress, timers and the app's own info.
// Everything goes through the host's `__cmuxAppNative` ABI; the host checks
// scopes and grants (the VM is untrusted), this layer only shapes the calls.

import { batch, onCleanup, signal, type Read } from "./reactive.ts"

export interface Native {
  call(name: string, paramsJSON: string, optionsJSON: string, cbId: number): void
  subscribe(stream: string, filterJSON: string): number
  unsubscribe(subId: number): void
  scene(mountId: string, opsJSON: string): void
  timer(ms: number, repeat: boolean): number
  clearTimer(timerId: number): void
  log(level: string, message: string): void
  commandDone(cbId: number, ok: boolean, resultJSON: string): void
}

export class CmuxError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly details?: unknown,
    readonly retryable = false
  ) {
    super(message)
    this.name = "CmuxError"
  }
}

export interface CallOptions {
  idempotencyKey?: string
  expectedRevision?: string
  /** A user-gesture token from cmux.gesture(); lets the owner accept a focus-changing op once. */
  gesture?: string
}

/** Ops the host always provides, whatever the catalog lists. */
const HOST_OPS = new Set(["action.run", "action.list", "app.storage.get", "app.storage.set", "app.storage.delete", "app.storage.keys", "app.settings.set", "net.fetch", "integration.request"])

export interface CallResult<T = unknown> {
  value: T
  revision?: string
  transaction?: string
  replayed?: boolean
}

type Pending = { resolve: (v: CallResult) => void; reject: (e: CmuxError) => void }

export const state = {
  native: null as Native | null,
  nextCallback: 1,
  pending: new Map<number, Pending>(),
  subscriptions: new Map<number, (payload: unknown) => void>(),
  timers: new Map<number, { fn: () => void; repeat: boolean }>(),
  app: { id: "", version: "" },
  apiVersion: "0.0.0",
  allowedOps: null as Set<string> | null,
  knownOps: null as Set<string> | null,
  /** The gesture token of the user event whose handler is running synchronously, else null. */
  gesture: null as string | null,
  locale: "en",
  strings: {} as Record<string, string>,
  settings: signal<Record<string, unknown>>({})
}

const native = (): Native => {
  if (!state.native) throw new CmuxError("app.host", "the cmux host is not attached")
  return state.native
}

export function log(level: "debug" | "info" | "warn" | "error", ...parts: unknown[]): void {
  const message = parts.map((p) => (typeof p === "string" ? p : safeJSON(p))).join(" ")
  state.native?.log(level, message)
}

const safeJSON = (v: unknown) => {
  try {
    return JSON.stringify(v)
  } catch {
    return String(v)
  }
}

/** Calls one catalog op; resolves with `{value, revision, transaction, replayed}`. */
export function callRaw<T = unknown>(name: string, params: unknown = {}, options: CallOptions = {}): Promise<CallResult<T>> {
  if (state.knownOps && !state.knownOps.has(name) && !HOST_OPS.has(name)) {
    return Promise.reject(new CmuxError("operation.unsupported", `${name} is not an operation of this cmux version`, { op: name }))
  }
  if (state.allowedOps && !state.allowedOps.has(name) && !HOST_OPS.has(name)) {
    return Promise.reject(new CmuxError("scope.missing", `this app cannot call ${name}`, { op: name }))
  }
  // Calls made synchronously inside a user handler carry its gesture; later calls only when passed explicitly.
  if (state.gesture && options.gesture === undefined) options = { ...options, gesture: state.gesture }
  const cbId = state.nextCallback++
  return new Promise<CallResult<T>>((resolve, reject) => {
    state.pending.set(cbId, { resolve: resolve as (v: CallResult) => void, reject })
    try {
      native().call(name, JSON.stringify(params ?? {}), JSON.stringify(options ?? {}), cbId)
    } catch (e) {
      state.pending.delete(cbId)
      reject(e instanceof CmuxError ? e : new CmuxError("app.host", String(e)))
    }
  })
}

/** Calls one op and resolves with its value. */
export const call = async <T = unknown>(name: string, params?: unknown, options?: CallOptions): Promise<T> => (await callRaw<T>(name, params, options)).value

export function resolveCall(cbId: number, ok: boolean, json: string): void {
  const p = state.pending.get(cbId)
  if (!p) return
  state.pending.delete(cbId)
  let body: Record<string, unknown> = {}
  try {
    body = json ? JSON.parse(json) : {}
  } catch {
    body = { code: "decode.invalid", message: "host returned invalid JSON" }
  }
  if (ok) p.resolve(body as unknown as CallResult)
  else p.reject(new CmuxError(String(body.code ?? "operation.failed"), String(body.message ?? "operation failed"), body.details, body.retryable === true))
}

export function on(stream: string, fn: (payload: unknown) => void, filter: unknown = {}): () => void {
  const subId = native().subscribe(stream, JSON.stringify(filter ?? {}))
  state.subscriptions.set(subId, fn)
  const off = () => {
    if (!state.subscriptions.delete(subId)) return
    state.native?.unsubscribe(subId)
  }
  onCleanup(off)
  return off
}

export function deliverEvent(subId: number, json: string): void {
  const fn = state.subscriptions.get(subId)
  if (!fn) return
  fn(json ? JSON.parse(json) : null)
}

type OpRef = string | { opName: string }
export type Live<T> = Read<T | undefined> & { error: Read<CmuxError | null>; loading: Read<boolean>; refresh: () => void }

/**
 * A signal holding the latest result of a read op. It re-reads when one of
 * `events` fires (default `<family>.changed`); a re-read requested while one is
 * in flight runs once after it, so bursts of events cost at most two reads.
 */
export function live<T = unknown>(op: OpRef, params: unknown = {}, options: { events?: string[]; select?: (v: unknown) => T } = {}): Live<T> {
  const name = typeof op === "string" ? op : op.opName
  const family = name.slice(0, name.lastIndexOf("."))
  const [value, setValue] = signal<T | undefined>(undefined, { equals: () => false })
  const [error, setError] = signal<CmuxError | null>(null)
  const [loading, setLoading] = signal(true)
  let inFlight = false
  let again = false
  const load = () => {
    if (inFlight) {
      again = true
      return
    }
    inFlight = true
    setLoading(true)
    call(name, params)
      .then((v) => {
        batch(() => {
          setValue(options.select ? options.select(v) : (v as T))
          setError(null)
        })
      })
      .catch((e: unknown) => setError(e instanceof CmuxError ? e : new CmuxError("operation.failed", String(e))))
      .finally(() => {
        inFlight = false
        setLoading(false)
        if (again) {
          again = false
          load()
        }
      })
  }
  for (const stream of options.events ?? [`${family}.changed`]) on(stream, load)
  load()
  const read = value as Live<T>
  Object.assign(read, { error, loading, refresh: load })
  return read
}

export function setTimer(ms: number, repeat: boolean, fn: () => void): number {
  const delay = repeat ? Math.max(1000, ms) : Math.max(0, ms)
  const id = native().timer(delay, repeat)
  state.timers.set(id, { fn, repeat })
  onCleanup(() => clearTimer(id))
  return id
}

export function clearTimer(id: number): void {
  if (state.timers.delete(id)) state.native?.clearTimer(id)
}

export function fireTimer(id: number): void {
  const t = state.timers.get(id)
  if (!t) return
  if (!t.repeat) state.timers.delete(id)
  t.fn()
}

export interface FetchResponse {
  status: number
  ok: boolean
  headers: Record<string, string>
  text(): string
  json<T = unknown>(): T
}

async function netFetch(url: string, init: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<FetchResponse> {
  const r = await call<{ status: number; headers?: Record<string, string>; body?: string }>("net.fetch", { url, method: init.method ?? "GET", headers: init.headers ?? {}, body: init.body ?? null })
  const body = r.body ?? ""
  return { status: r.status, ok: r.status >= 200 && r.status < 300, headers: r.headers ?? {}, text: () => body, json: <T>() => JSON.parse(body) as T }
}

const opFunction = (name: string) => {
  const fn = (params?: unknown, options?: CallOptions) => call(name, params, options)
  return Object.assign(fn, { opName: name, raw: (params?: unknown, options?: CallOptions) => callRaw(name, params, options) })
}

const familyProxy = (prefix: string): unknown =>
  new Proxy(Object.create(null), {
    get(_t, key) {
      if (typeof key !== "string" || key === "then") return undefined
      return familyOrOp(`${prefix}.${key}`)
    }
  })

// `cmux.browser.session.open` is a nested family; `cmux.workspace.list` an op.
// A member is callable as an op and also indexable as a deeper family.
const familyOrOp = (name: string): unknown =>
  new Proxy(opFunction(name), {
    get(target, key) {
      if (key in target) return (target as unknown as Record<string | symbol, unknown>)[key]
      if (typeof key !== "string" || key === "then") return undefined
      return familyOrOp(`${name}.${key}`)
    }
  })

const builtins: Record<string, unknown> = {
  call,
  callRaw,
  live,
  log: (...parts: unknown[]) => log("info", ...parts),
  CmuxError,
  events: { on },
  actions: { run: (id: string, args: Record<string, unknown> = {}) => call("action.run", { id, args }), list: () => call("action.list", {}) },
  storage: {
    get: <T = unknown>(key: string) => call<T | null>("app.storage.get", { key }),
    set: (key: string, value: unknown) => call("app.storage.set", { key, value }),
    delete: (key: string) => call("app.storage.delete", { key }),
    keys: () => call<string[]>("app.storage.keys", {})
  },
  net: { fetch: netFetch },
  integrations: new Proxy(Object.create(null), {
    get: (_t, provider) => (typeof provider === "string" ? { request: (params: Record<string, unknown>) => call("integration.request", { provider, ...params }) } : undefined)
  }),
  timer: { after: (ms: number, fn: () => void) => setTimer(ms, false, fn), every: (ms: number, fn: () => void) => setTimer(ms, true, fn), clear: clearTimer },
  app: {
    get id() {
      return state.app.id
    },
    get version() {
      return state.app.version
    },
    get apiVersion() {
      return state.apiVersion
    },
    get locale() {
      return state.locale
    },
    settings: Object.assign(() => state.settings[0](), {
      set: (values: Record<string, unknown>) => call("app.settings.set", { values })
    })
  },
  /** The current user-gesture token (only inside a user event handler, before its first await). */
  gesture: () => state.gesture,
  /** The app's string for `key` in the user's locale (strings/<lang>.json), else `fallback`; `{name}` placeholders. */
  t: (key: string, fallbackOrParams?: string | Record<string, unknown>, params?: Record<string, unknown>) => {
    const fallback = typeof fallbackOrParams === "string" ? fallbackOrParams : key
    const values = (typeof fallbackOrParams === "object" ? fallbackOrParams : params) ?? {}
    return (state.strings[key] ?? fallback).replace(/\{(\w+)\}/g, (m, k: string) => (k in values ? String(values[k]) : m))
  }
}

export const cmux: Record<string, unknown> = new Proxy(builtins, {
  get(target, key) {
    if (typeof key !== "string") return undefined
    if (key in target) return target[key]
    if (key === "then") return undefined
    return familyProxy(key)
  }
})
