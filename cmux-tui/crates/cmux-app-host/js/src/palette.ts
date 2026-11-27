// Palette sources for app palette scopes (plans/cmux-next/palette-scopes.md
// section 6). Apps export `palette.snapshot`, `palette.query` and
// `palette.detail` wrappers; the host drives them through
// `__cmuxAppPaletteOpen` / `__cmuxAppPaletteCancel` / `__cmuxAppPaletteDetail`
// and receives items through `paletteBatch` / `paletteDone` (ABI.md). Items
// are plain data with typed `ActionRef`s; no closures cross the boundary.

import { CmuxError, log, state, type AbortSignalLike } from "./cmux.ts"

export const PALETTE_LIMITS = {
  /** UTF-8 bytes of one item's JSON. */
  itemBytes: 2048,
  /** Items of one snapshot. */
  snapshotItems: 10_000,
  /** Items of one query batch, and of every `paletteBatch` call. */
  batchItems: 200,
  /** Live rows of one query request across all its yields (and of one cached result). */
  queryItems: 1000,
  /** UTF-8 bytes of one detail's JSON. */
  detailBytes: 64 * 1024,
  /** Queries remembered per cache key (scope, session, context, filter) for `palette.cached()`. */
  cachedQueries: 32
}

export interface ActionRef {
  id: string
  args: Record<string, unknown>
  title?: string
  symbol?: string
}

export interface PaletteItem {
  id: string
  title: string
  subtitle?: string
  symbol?: string
  keywords?: string[]
  accessory?: Record<string, unknown>
  actions?: ActionRef[]
  /** Tab drills into this scope with the item as context (default `actions`). */
  drill?: string
  /** A scope row: Return or Tab enters this scope. */
  enters?: string
}

type Kind = "snapshot" | "query" | "detail"
const KIND = "__cmuxPaletteKind"
const CACHED = "__cmuxPaletteCached"

const describe = (e: unknown) => (e instanceof Error ? e.message : String(e))

/** A small AbortSignal for engines without one (QuickJS-ng). */
export class PaletteAbortSignal implements AbortSignalLike {
  aborted = false
  reason: unknown = undefined
  onabort: ((ev: { type: "abort" }) => void) | null = null
  private listeners: Array<() => void> = []

  addEventListener(type: "abort", fn: () => void) {
    if (type === "abort" && !this.listeners.includes(fn)) this.listeners.push(fn)
  }

  removeEventListener(type: "abort", fn: () => void) {
    if (type === "abort") this.listeners = this.listeners.filter((l) => l !== fn)
  }

  throwIfAborted() {
    if (this.aborted) throw this.reason
  }

  /** Runtime-internal. */
  abort(reason: unknown = new CmuxError("aborted", "the request was cancelled")) {
    if (this.aborted) return
    this.aborted = true
    this.reason = reason
    const listeners = this.listeners
    this.listeners = []
    for (const fn of listeners) {
      try {
        fn()
      } catch (e) {
        log("error", `abort listener: ${describe(e)}`)
      }
    }
    try {
      this.onabort?.({ type: "abort" })
    } catch (e) {
      log("error", `onabort: ${describe(e)}`)
    }
  }
}

const tag = <F extends (...args: never[]) => unknown>(fn: F, kind: Kind): F => {
  if (typeof fn !== "function") throw new CmuxError("palette.invalid", `palette.${kind} needs a function`)
  const wrapper = ((...args: never[]) => fn(...args)) as F
  Object.defineProperty(wrapper, KIND, { value: kind })
  return wrapper
}

export const kindOf = (fn: unknown): Kind | undefined => (typeof fn === "function" ? ((fn as unknown as Record<string, unknown>)[KIND] as Kind | undefined) : undefined)

// MARK: Validation

/** UTF-8 byte length without TextEncoder (not every engine has it). */
export function utf8Length(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      n += 4
      i++
    } else n += 3
  }
  return n
}

/** Throws `palette.invalid` at the first value JSON cannot carry (functions, symbols, bigints, cycles). */
function checkPlain(value: unknown, path: string, seen: unknown[] = []): void {
  const t = typeof value
  if (t === "function") throw new CmuxError("palette.invalid", `${path} is a function; items carry ActionRefs (act(op, args)), never closures`, { path })
  if (t === "symbol" || t === "bigint") throw new CmuxError("palette.invalid", `${path} is a ${t}`, { path })
  if (value === null || t !== "object") return
  if (seen.includes(value)) throw new CmuxError("palette.invalid", `${path} is circular`, { path })
  seen.push(value)
  if (Array.isArray(value)) value.forEach((v, i) => checkPlain(v, `${path}[${i}]`, seen))
  else for (const [k, v] of Object.entries(value as Record<string, unknown>)) checkPlain(v, `${path}.${k}`, seen)
  seen.pop()
}

function checkActionRef(ref: unknown, path: string): void {
  const r = ref as Record<string, unknown>
  if (!r || typeof r !== "object" || typeof r.id !== "string" || !r.id) throw new CmuxError("palette.invalid", `${path} is not an ActionRef (use act(op, args))`, { path })
  if (r.args !== undefined && (typeof r.args !== "object" || r.args === null || Array.isArray(r.args))) throw new CmuxError("palette.invalid", `${path}.args must be an object`, { path })
}

/** Serializes `value` once; the caller validates the parsed result, never the live object (a toJSON or getter cannot change it after the checks). */
function serialize(value: unknown, path: string): string {
  checkPlain(value, path)
  let json: string | undefined
  try {
    json = JSON.stringify(value)
  } catch (e) {
    throw new CmuxError("palette.invalid", `${path} cannot be serialized: ${describe(e)}`, { path })
  }
  if (json === undefined) throw new CmuxError("palette.invalid", `${path} is not JSON`, { path })
  return json
}

/** Validates one item and returns its JSON: the checks run on the serialized form that is sent. */
export function itemJSON(item: unknown, path: string): string {
  const json = serialize(item, path)
  const it = JSON.parse(json) as Record<string, unknown>
  if (!it || typeof it !== "object" || Array.isArray(it)) throw new CmuxError("palette.invalid", `${path} is not an object`, { path })
  if (typeof it.id !== "string" || !it.id) throw new CmuxError("palette.invalid", `${path}.id must be a non-empty string`, { path })
  if (typeof it.title !== "string") throw new CmuxError("palette.invalid", `${path}.title must be a string`, { path })
  if (it.actions !== undefined) {
    if (!Array.isArray(it.actions)) throw new CmuxError("palette.invalid", `${path}.actions must be an array of ActionRefs`, { path })
    it.actions.forEach((a, i) => checkActionRef(a, `${path}.actions[${i}]`))
  }
  for (const key of ["drill", "enters"]) if (it[key] !== undefined && typeof it[key] !== "string") throw new CmuxError("palette.invalid", `${path}.${key} must be a scope id`, { path })
  const bytes = utf8Length(json)
  if (bytes > PALETTE_LIMITS.itemBytes) throw new CmuxError("palette.limit", `${path} is ${bytes} bytes; an item is at most ${PALETTE_LIMITS.itemBytes}`, { path, bytes })
  return json
}

function itemsJSON(items: unknown, limit: number, what: string): string[] {
  if (!Array.isArray(items)) throw new CmuxError("palette.invalid", `${what} must be an array of items`)
  if (items.length > limit) throw new CmuxError("palette.limit", `${what} has ${items.length} items; at most ${limit}`, { count: items.length, limit })
  return items.map((item, i) => itemJSON(item, `${what}[${i}]`))
}

// MARK: App API

/** Builds a typed reference to a catalog action or op (`note.open`, `app:<id>#<cmd>`). */
export function act(op: string, args: Record<string, unknown> = {}, overrides: { title?: string; symbol?: string } = {}): ActionRef {
  if (typeof op !== "string" || !op) throw new CmuxError("palette.invalid", "act needs an action id")
  if (args === null || typeof args !== "object" || Array.isArray(args)) throw new CmuxError("palette.invalid", `act(${op}): args must be an object`)
  const ref: ActionRef = { id: op, args: JSON.parse(serialize(args, `act(${op}).args`)) }
  if (overrides.title !== undefined) ref.title = String(overrides.title)
  if (overrides.symbol !== undefined) ref.symbol = String(overrides.symbol)
  return ref
}

export interface PaletteContext {
  /** The manifest scope id. */
  readonly scope: string
  readonly generation: number
  readonly signal: PaletteAbortSignal
  /** The drilled or entered row id, when the level has one. */
  readonly context?: string
  /** The chosen filter id. */
  readonly filter?: string
  /** The host's palette level (one request per level is live). */
  readonly session?: string
}

const cachedMarker = Object.freeze({ [CACHED]: true })

export const palette = {
  /** A snapshot source: the whole candidate set, ranked by the host; runs once per invalidation, never per keystroke. */
  snapshot: <F extends (ctx: PaletteContext) => unknown>(fn: F) => tag(fn, "snapshot"),
  /** A query source: an async generator; every `yield` is a batch. A new query aborts the old one through `ctx.signal`. */
  query: <F extends (query: string, ctx: PaletteContext) => unknown>(fn: F) => tag(fn, "query"),
  /** Detail of the highlighted row (`listWithDetail`), loaded lazily. */
  detail: <F extends (itemId: string, ctx: { scope: string }) => unknown>(fn: F) => tag(fn, "detail"),
  /** Yield this from a query source to send the last complete result of the longest cached prefix of the query. */
  cached: () => cachedMarker
}

// MARK: Host side

interface ScopeDecl {
  source?: { kind?: string; export?: string }
  detail?: { export?: string }
}

interface Request {
  id: number
  key: string
  signal: PaletteAbortSignal
  generation: number
  /** Sent nothing more once true (cancelled, superseded or done). */
  closed: boolean
  /** No batch sent yet: the next one replaces the level's rows. */
  fresh: boolean
  /** The last batch came from `palette.cached()`: the next live batch replaces it. */
  provisional: boolean
}

export const paletteState = {
  scopes: new Map<string, ScopeDecl>(),
  requests: new Map<number, Request>(),
  /** Request key (scope + session) -> live request id. */
  live: new Map<string, number>(),
  /** Scope -> query -> items JSON of the last complete result (LRU by insertion). */
  cache: new Map<string, Map<string, string[]>>()
}

/** `__cmuxAppInit` passes the manifest's `contributes.paletteScopes`. */
export function setPaletteScopes(list: unknown) {
  paletteState.scopes.clear()
  if (!Array.isArray(list)) return
  for (const s of list as Array<ScopeDecl & { id?: string }>) if (s && typeof s.id === "string") paletteState.scopes.set(s.id, s)
}

const exportsOf = (): Record<string, unknown> => ((globalThis as Record<string, unknown>).__cmuxAppExports as Record<string, unknown> | undefined) ?? {}

const failure = (e: unknown) => (e instanceof CmuxError ? { code: e.code, message: e.message, details: e.details ?? null } : { code: "palette.failed", message: describe(e) })

/**
 * Sends one batch. `replace` is true for the request's first batch and for
 * the first live batch after a `palette.cached()` batch (so provisional rows
 * never outlive the live result); later batches append.
 */
function send(req: Request, items: string[], isFinal: boolean, cached = false) {
  if (req.closed) return
  const n = state.native
  if (!n?.paletteBatch) throw new CmuxError("app.host", "the host does not implement paletteBatch")
  const replace = req.fresh || (req.provisional && !cached)
  req.fresh = false
  req.provisional = cached
  n.paletteBatch(req.id, req.generation, `[${items.join(",")}]`, isFinal, replace)
}

/** Sends `items` in chunks of at most `batchItems`; the last chunk carries `isFinal`. */
function sendChunked(req: Request, items: string[], isFinal: boolean, cached = false) {
  if (!items.length) {
    if (isFinal) send(req, [], true)
    return
  }
  for (let i = 0; i < items.length; i += PALETTE_LIMITS.batchItems) {
    const chunk = items.slice(i, i + PALETTE_LIMITS.batchItems)
    send(req, chunk, isFinal && i + PALETTE_LIMITS.batchItems >= items.length, cached)
  }
}

function finish(req: Request, ok: boolean, body: unknown) {
  if (req.closed) return
  req.closed = true
  paletteState.requests.delete(req.id)
  if (paletteState.live.get(req.key) === req.id) paletteState.live.delete(req.key)
  state.native?.paletteDone?.(req.id, ok, JSON.stringify(body ?? null))
}

/** `palette.cached()` results are per scope, session, drilled row and filter: one level's rows never show in another. */
const cacheKey = (scope: string, ctx: { session?: string; context?: string; filter?: string }) => [scope, ctx.session ?? "", ctx.context ?? "", ctx.filter ?? ""].join("\u0000")

function remember(key: string, query: string, items: string[]) {
  let perScope = paletteState.cache.get(key)
  if (!perScope) paletteState.cache.set(key, (perScope = new Map()))
  perScope.delete(query)
  perScope.set(query, items.slice(0, PALETTE_LIMITS.queryItems))
  while (perScope.size > PALETTE_LIMITS.cachedQueries) perScope.delete(perScope.keys().next().value as string)
}

/** The last complete result of the longest cached prefix of `query` (exact match first). */
function cachedFor(key: string, query: string): string[] | undefined {
  const perScope = paletteState.cache.get(key)
  if (!perScope) return undefined
  let best: string | undefined
  for (const q of perScope.keys()) if (query.startsWith(q) && (best === undefined || q.length > best.length)) best = q
  return best === undefined ? undefined : perScope.get(best)
}

const isCachedMarker = (v: unknown) => !!v && typeof v === "object" && (v as Record<string, unknown>)[CACHED] === true

async function pumpQuery(req: Request, key: string, query: string, source: unknown) {
  const all: string[] = []
  let truncated = false
  const it = source as AsyncIterator<unknown> & { return?: (v?: unknown) => unknown }
  try {
    if (!source || typeof (it as { next?: unknown }).next !== "function") {
      // A plain async function returning one array: one final batch.
      const items = itemsJSON(await source, PALETTE_LIMITS.batchItems, "the query result")
      if (req.closed) return
      remember(key, query, items)
      sendChunked(req, items, true)
      finish(req, true, { count: items.length })
      return
    }
    for (;;) {
      const step = await it.next()
      if (req.closed) {
        await it.return?.()
        return
      }
      if (step.done) break
      if (isCachedMarker(step.value)) {
        const cached = cachedFor(key, query)
        if (cached?.length) sendChunked(req, cached, false, true)
        continue
      }
      let items = itemsJSON(step.value, PALETTE_LIMITS.batchItems, "a query batch")
      const room = PALETTE_LIMITS.queryItems - all.length
      if (items.length > room) {
        items = items.slice(0, room)
        truncated = true
      }
      all.push(...items)
      if (items.length) sendChunked(req, items, false)
      if (truncated) {
        // The request reached its total: stop the source, keep what was sent.
        await it.return?.()
        break
      }
    }
    remember(key, query, all)
    send(req, [], true)
    finish(req, true, truncated ? { count: all.length, truncated: true } : { count: all.length })
  } catch (e) {
    if (req.closed) return
    try {
      await it.return?.()
    } catch {
      // The generator is already finishing.
    }
    finish(req, false, failure(e))
  }
}

async function runSnapshot(req: Request, fn: (ctx: PaletteContext) => unknown, ctx: PaletteContext) {
  try {
    const items = itemsJSON(await fn(ctx), PALETTE_LIMITS.snapshotItems, "the snapshot")
    if (req.closed) return
    sendChunked(req, items, true)
    finish(req, true, { count: items.length })
  } catch (e) {
    finish(req, false, failure(e))
  }
}

/** `__cmuxAppPaletteOpen`: starts a snapshot or query request. Returns "" or an error message (also sent as paletteDone). */
export function paletteOpen(scopeId: string, kind: string, query: string, generation: number, ctxJSON: string, reqId: number): string {
  let ctxIn: { session?: string; context?: string; filter?: string } = {}
  let ctxValid = true
  try {
    const parsed = ctxJSON ? JSON.parse(ctxJSON) : {}
    if (parsed && typeof parsed === "object") ctxIn = parsed
    else ctxValid = false
  } catch {
    ctxValid = false
  }
  const key = `${scopeId}\u0000${ctxIn.session ?? ""}`
  // A new request for the same scope and session supersedes the old one.
  const previous = paletteState.live.get(key)
  if (previous !== undefined) paletteCancel(previous)
  const req: Request = { id: reqId, key, signal: new PaletteAbortSignal(), generation, closed: false, fresh: true, provisional: false }
  paletteState.requests.set(reqId, req)
  paletteState.live.set(key, reqId)
  const reject = (code: string, message: string) => {
    finish(req, false, { code, message, details: { scope: scopeId } })
    return message
  }
  if (!ctxValid) return reject("palette.invalid", "ctxJSON is not a JSON object")
  const decl = paletteState.scopes.get(scopeId)
  if (!decl) return reject("palette.scope", `the app declares no palette scope ${scopeId}`)
  if (kind !== "snapshot" && kind !== "query") return reject("palette.kind", `unknown source kind ${kind}`)
  const exportName = decl.source?.export
  const fn = exportName ? exportsOf()[exportName] : undefined
  if (typeof fn !== "function") return reject("export.missing", `the app does not export ${exportName ?? "(none)"}`)
  const declared = kindOf(fn)
  if (declared && declared !== kind) return reject("palette.kind", `${exportName} is a palette.${declared} source, not ${kind}`)
  const ctx: PaletteContext = {
    scope: scopeId,
    generation,
    signal: req.signal,
    ...(ctxIn.context !== undefined ? { context: ctxIn.context } : {}),
    ...(ctxIn.filter !== undefined ? { filter: ctxIn.filter } : {}),
    ...(ctxIn.session !== undefined ? { session: ctxIn.session } : {})
  }
  if (kind === "snapshot") {
    runSnapshot(req, fn as (ctx: PaletteContext) => unknown, ctx)
    return ""
  }
  let source: unknown
  try {
    source = (fn as (q: string, ctx: PaletteContext) => unknown)(query, ctx)
  } catch (e) {
    finish(req, false, failure(e))
    return describe(e)
  }
  pumpQuery(req, cacheKey(scopeId, ctxIn), query, source)
  return ""
}

/** `__cmuxAppPaletteCancel`: aborts the request; the runtime sends nothing more for it. */
export function paletteCancel(reqId: number) {
  const req = paletteState.requests.get(reqId)
  if (!req) return
  req.closed = true
  paletteState.requests.delete(reqId)
  if (paletteState.live.get(req.key) === reqId) paletteState.live.delete(req.key)
  req.signal.abort()
}

/** `__cmuxAppPaletteDetail`: answers with paletteDone(reqId, ok, detail JSON). */
export function paletteDetail(scopeId: string, itemId: string, reqId: number) {
  const req: Request = { id: reqId, key: `detail\u0000${reqId}`, signal: new PaletteAbortSignal(), generation: 0, closed: false, fresh: true, provisional: false }
  paletteState.requests.set(reqId, req)
  const decl = paletteState.scopes.get(scopeId)
  const exportName = decl?.detail?.export
  const fn = exportName ? exportsOf()[exportName] : undefined
  if (!decl) return finish(req, false, { code: "palette.scope", message: `the app declares no palette scope ${scopeId}` })
  if (typeof fn !== "function") return finish(req, false, { code: "export.missing", message: `scope ${scopeId} has no detail export` })
  Promise.resolve()
    .then(() => (fn as (id: string, ctx: { scope: string; signal: PaletteAbortSignal }) => unknown)(itemId, { scope: scopeId, signal: req.signal }))
    .then((detail) => {
      if (req.closed) return
      const json = serialize(detail ?? null, "detail")
      const bytes = utf8Length(json)
      if (bytes > PALETTE_LIMITS.detailBytes) throw new CmuxError("palette.limit", `detail is ${bytes} bytes; at most ${PALETTE_LIMITS.detailBytes}`)
      finish(req, true, JSON.parse(json))
    })
    .catch((e) => finish(req, false, failure(e)))
}
