// @cmux/app-test: loads a cmux app directory into the reference fake host
// with op fixtures and grants, and drives its palette scopes through a
// TypeScript port of the palette navigation reducer. Private, never
// published. README.md next to this package documents the API.

import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "../../js/test/fake-host.ts"
import { SchemaValidator } from "../../tools/json-schema.ts"
import { validatePackage } from "../../tools/validate-manifest.ts"
import { PaletteSession } from "./session.ts"

export { PaletteSession } from "./session.ts"
export * from "./nav.ts"
export { runVector, NavDriver, invariantViolations, type VectorCase } from "./vectors.ts"
export { rank, score } from "./rank.ts"

const generated = JSON.parse(readFileSync(new URL("../../generated/scopes.json", import.meta.url), "utf8")) as { ops: Record<string, { scope: string; class: string }>; never: string[] }

export type Fixture = unknown | ((params: any, call: { origin: Origin }) => unknown)
export type Origin = "user" | "script"

export interface HarnessOptions {
  /** Granted scopes. Default: every key of the manifest's `scopes` and `optionalScopes`. */
  grants?: string[]
  /** Op results by op name: a value, or a function of the params (may throw a `{code, message}` object). */
  fixtures?: Record<string, Fixture>
  settings?: Record<string, unknown>
  /** The app's local storage before the run. */
  storage?: Record<string, unknown>
  /** Run every snapshot source once at load, the way the supervisor's cache holds the last snapshot from an earlier run. Default true. */
  warm?: boolean
  /** Validate the package like `cmux apps validate` and throw on errors. Default true. */
  validate?: boolean
}

export interface OpCall {
  op: string
  args: unknown
}

export interface OpLogEntry extends OpCall {
  origin: Origin
  ok: boolean
  code?: string
}

export interface ActionRef {
  id: string
  args?: Record<string, unknown>
  title?: string
  symbol?: string
}

export interface PaletteItem {
  id: string
  title: string
  subtitle?: string
  symbol?: string
  keywords?: string[]
  actions?: ActionRef[]
  drill?: string
  enters?: string
  [key: string]: unknown
}

export interface ScopeDecl {
  id: string
  title: string | Record<string, string>
  symbol?: string
  keywords?: string[]
  prefix?: string
  layout?: string
  ranking?: "fuzzy" | "recency" | "source"
  source: { kind: "snapshot" | "query" | "op"; export?: string; invalidatedBy?: string[]; minQueryLength?: number; op?: string; item?: Record<string, string> }
  primary?: string
  detail?: { export: string }
  children?: string[]
}

export interface CommandDecl {
  id: string
  title: string | Record<string, string>
  run: string
  mode?: "run" | "form" | "view"
  arguments?: Record<string, unknown>
  keywords?: string[]
  contexts?: string[]
}

export type Result = { ok: true; value: unknown } | { ok: false; error: { code: string; message: string; details?: unknown } }

const READ_VERBS = new Set(["list", "get", "search", "query", "read", "count", "counts", "find", "show", "info", "status"])

export const localized = (t: string | Record<string, string> | undefined, fallback = ""): string => (t === undefined ? fallback : typeof t === "string" ? t : (t.en ?? Object.values(t)[0] ?? fallback))

const opError = (code: string, message: string, details?: unknown) => ({ ok: false as const, body: { code, message, details: details ?? null, retryable: false } })

/** A loaded app. Create with `harness.load(dir, options)`. */
export class AppHarness {
  readonly manifest: Record<string, any>
  readonly appId: string
  readonly host: FakeHost
  readonly grants: Set<string>
  readonly fixtures: Record<string, Fixture>
  readonly ops = { calls: [] as OpCall[], log: [] as OpLogEntry[] }
  readonly storage = new Map<string, unknown>()
  clipboard: string | null = null
  readonly scopes = new Map<string, ScopeDecl>()
  readonly commandDecls: Map<string, CommandDecl>
  /** The supervisor's last snapshot per scope (manifest id) and which ones an event invalidated. */
  readonly snapshotCache = new Map<string, PaletteItem[]>()
  readonly dirty = new Set<string>()
  readonly vm = {
    running: true,
    /** Calls into the VM for palette sources (open and detail). */
    paletteRequests: 0,
    stop: () => {
      this.vm.running = false
    },
    start: () => {
      this.vm.running = true
    }
  }
  /** Open palette sessions (`palette.open`). */
  readonly sessions = new Set<PaletteSession>()
  inflight = 0
  private readonly liveGestures = new Set<string>()
  private nextGesture = 1
  private nextCb = 1
  private nextReq = 1
  private readonly commandWaiters = new Map<number, (r: Result) => void>()
  private readonly paletteHandlers = new Map<number, { batch: (items: PaletteItem[], isFinal: boolean, generation: number, replace: boolean) => void; done: (ok: boolean, body: any) => void }>()

  constructor(readonly dir: string, options: HarnessOptions = {}) {
    if (options.validate !== false) {
      const result = validatePackage(dir)
      if (!result.ok) throw new Error(`${dir} is not a valid app:\n${result.errors.map((e) => `  ${e.path || "/"} ${e.code}: ${e.message}`).join("\n")}`)
    }
    this.manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
    this.appId = this.manifest.id
    const contributes = this.manifest.contributes ?? {}
    for (const s of (contributes.paletteScopes ?? []) as ScopeDecl[]) this.scopes.set(s.id, s)
    this.commandDecls = new Map(((contributes.commands ?? []) as CommandDecl[]).map((c) => [c.id, c]))
    this.grants = new Set(options.grants ?? [...Object.keys(this.manifest.scopes ?? {}), ...Object.keys(this.manifest.optionalScopes ?? {})])
    this.fixtures = options.fixtures ?? {}
    for (const [k, v] of Object.entries(options.storage ?? {})) this.storage.set(k, structuredClone(v))
    const defaults = Object.fromEntries(Object.entries((contributes.settings?.properties ?? {}) as Record<string, { default?: unknown }>).filter(([, p]) => "default" in p).map(([k, p]) => [k, p.default]))
    const main = this.manifest.main ? readFileSync(join(dir, this.manifest.main), "utf8") : ""
    this.host = new FakeHost(main, {
      app: { id: this.appId, version: this.manifest.version },
      apiVersion: "1.0.0",
      settings: { ...defaults, ...(options.settings ?? {}) },
      paletteScopes: [...this.scopes.values()]
    })
    this.host.fallback = (name, params, options) => this.resolveOp(name, params, this.originOf(options))
    this.host.onCommandDone = (cbId, ok, body) => {
      const waiter = this.commandWaiters.get(cbId)
      if (!waiter) return
      this.commandWaiters.delete(cbId)
      waiter(ok ? { ok: true, value: body.value } : { ok: false, error: body })
    }
    this.host.onPaletteBatch = (b) => this.paletteHandlers.get(b.reqId)?.batch(b.items, b.isFinal, b.generation, b.replace)
    this.host.onPaletteDone = (reqId, ok, body) => {
      const h = this.paletteHandlers.get(reqId)
      if (!h) return
      this.paletteHandlers.delete(reqId)
      this.inflight--
      h.done(ok, body)
    }
  }

  /** Lets the VM and the fake host settle: promise continuations, streamed batches, command completions. */
  async idle(maxRounds = 200) {
    for (let i = 0; i < maxRounds; i++) {
      await new Promise((r) => setImmediate(r))
      if (this.inflight <= 0 && i >= 2) return
    }
  }

  /** Fires a host event: invalidates snapshot scopes that list it, refreshes open sessions on them, and delivers it to the app's subscriptions. */
  emit(event: string, payload: unknown = {}) {
    for (const [id, s] of this.scopes) {
      if (s.source.kind === "snapshot" && (s.source.invalidatedBy ?? []).includes(event)) {
        this.dirty.add(id)
        for (const session of this.sessions) session.invalidated(this.fullScopeID(id))
      }
    }
    this.host.emit(event, payload)
  }

  fullScopeID(local: string) {
    return `app:${this.appId}#${local}`
  }

  // MARK: Ops

  private originOf(options: any): Origin {
    return typeof options?.gesture === "string" && this.liveGestures.has(options.gesture) ? "user" : "script"
  }

  /** The scope an op needs, or null when it needs none (the app's own storage). */
  scopeFor(op: string, params: any): string | null {
    if (op.startsWith("app.storage.")) return null
    if (op === "net.fetch") {
      try {
        return `net:${new URL(String(params?.url)).hostname}`
      } catch {
        return "net:<invalid>"
      }
    }
    if (op === "integration.request") return `integration:${params?.provider}`
    const known = generated.ops[op]
    if (known) return known.scope
    const parts = op.split(".")
    const verb = parts.at(-1) === "stream" ? parts.at(-2)! : parts.at(-1)!
    return `${parts[0]}:${READ_VERBS.has(verb) ? "read" : "write"}`
  }

  granted(scope: string, op: string, params: any): boolean {
    if (this.grants.has(scope)) return true
    if (scope.startsWith("net:")) {
      const host = scope.slice(4)
      return [...this.grants].some((g) => g.startsWith("net:*.") && host.endsWith(g.slice(5)))
    }
    if (op === "integration.request") return this.grants.has(`${scope}:read`) && String(params?.method ?? "GET").toUpperCase() === "GET"
    return false
  }

  /** Every op call from the VM, and every ActionRef the palette runs, lands here. */
  async resolveOp(op: string, params: any, origin: Origin): Promise<{ ok: boolean; body: unknown }> {
    this.ops.calls.push({ op, args: params ?? {} })
    const reply = await this.answer(op, params ?? {}, origin)
    const body = reply.body as { code?: string }
    this.ops.log.push({ op, args: params ?? {}, origin, ok: reply.ok, ...(reply.ok ? {} : { code: body.code }) })
    return reply
  }

  private async answer(op: string, params: any, origin: Origin): Promise<{ ok: boolean; body: unknown }> {
    if (generated.never.includes(op)) return opError("operation.forbidden", `apps never call ${op}`, { op })
    const hasFixture = Object.hasOwn(this.fixtures, op)
    const builtin = op.startsWith("app.storage.") || op === "clipboard.write"
    if (!hasFixture && !builtin && !generated.ops[op]) return opError("operation.unsupported", `no owner implements ${op} (add a fixture to test against it)`, { op })
    const scope = this.scopeFor(op, params)
    if (scope && !this.granted(scope, op, params)) return opError("scope.missing", `${op} needs scope ${scope}`, { op, scope })
    if (hasFixture) {
      const f = this.fixtures[op]
      try {
        const value = typeof f === "function" ? await (f as (p: any, c: { origin: Origin }) => unknown)(params, { origin }) : structuredClone(f)
        return { ok: true, body: { value: value ?? null } }
      } catch (e) {
        const err = e as { code?: string; message?: string; details?: unknown }
        return opError(err.code ?? "operation.failed", err.message ?? String(e), err.details)
      }
    }
    switch (op) {
      case "app.storage.get":
        return { ok: true, body: { value: this.storage.has(params.key) ? structuredClone(this.storage.get(params.key)) : null } }
      case "app.storage.set":
        this.storage.set(params.key, structuredClone(params.value))
        queueMicrotask(() => this.emit("app.storage.changed", { key: params.key }))
        return { ok: true, body: { value: null } }
      case "app.storage.delete":
        this.storage.delete(params.key)
        queueMicrotask(() => this.emit("app.storage.changed", { key: params.key }))
        return { ok: true, body: { value: null } }
      case "app.storage.keys":
        return { ok: true, body: { value: [...this.storage.keys()] } }
      case "clipboard.write":
        this.clipboard = String(params.text ?? "")
        return { ok: true, body: { value: null } }
    }
    return opError("fixture.missing", `${op} is in the catalog but the test gave no fixture for it`, { op })
  }

  /** Runs an ActionRef the way the palette host does: the app's own commands through the VM with a gesture, everything else as a user-origin op. */
  async runAction(ref: ActionRef, origin: Origin = "user"): Promise<Result> {
    const own = new RegExp(`^app:${this.appId.replace(/[/\\^$.*+?()[\]{}|-]/g, "\\$&")}#(.+)$`).exec(ref.id)
    if (own) {
      this.ops.calls.push({ op: ref.id, args: ref.args ?? {} })
      const result = await this.runCommand(own[1]!, ref.args ?? {})
      this.ops.log.push({ op: ref.id, args: ref.args ?? {}, origin, ok: result.ok, ...(result.ok ? {} : { code: result.error.code }) })
      return result
    }
    const reply = await this.resolveOp(ref.id, ref.args ?? {}, origin)
    const body = reply.body as { value?: unknown; code: string; message: string }
    return reply.ok ? { ok: true, value: body.value ?? null } : { ok: false, error: { code: body.code, message: body.message } }
  }

  // MARK: Commands

  /** Runs command `id` with a fresh user gesture, after checking `args` against its `arguments` schema. */
  async runCommand(id: string, args: Record<string, unknown> = {}): Promise<Result> {
    const cmd = this.commandDecls.get(id)
    if (!cmd) return { ok: false, error: { code: "command.unknown", message: `the app has no command ${id}` } }
    if (cmd.arguments) {
      const errors = new SchemaValidator(cmd.arguments).validate(args)
      if (errors.length) return { ok: false, error: { code: "invalid_params", message: errors.map((e) => `${e.path || "/"} ${e.message}`).join("; "), details: errors } }
    }
    if (!this.vm.running) return { ok: false, error: { code: "vm.stopped", message: "the app is not running" } }
    const gesture = `g-${this.nextGesture++}`
    const cbId = this.nextCb++
    this.liveGestures.add(gesture)
    this.inflight++
    const result = new Promise<Result>((resolve) => this.commandWaiters.set(cbId, resolve))
    this.host.runCommand(cmd.run, args, cbId, { gesture })
    const r = await result
    this.liveGestures.delete(gesture)
    this.inflight--
    return r
  }

  // MARK: Palette sources

  /** Starts a source request in the VM; batches and the end go to the callbacks. Returns the request id, or null when the VM is stopped. */
  openSource(local: string, kind: "snapshot" | "query", query: string, generation: number, ctx: Record<string, unknown>, onBatch: (items: PaletteItem[], isFinal: boolean, generation: number, replace: boolean) => void, onDone: (ok: boolean, body: any) => void): number | null {
    if (!this.vm.running) return null
    const reqId = this.nextReq++
    this.paletteHandlers.set(reqId, { batch: onBatch, done: onDone })
    this.inflight++
    this.vm.paletteRequests++
    this.host.paletteOpen(local, kind, query, generation, reqId, ctx)
    return reqId
  }

  cancelSource(reqId: number) {
    if (!this.paletteHandlers.delete(reqId)) return
    this.inflight--
    this.host.paletteCancel(reqId)
  }

  private readonly refreshing = new Map<string, Promise<PaletteItem[] | null>>()

  /** Runs a snapshot source in the VM and stores the result as the supervisor's cache. One run per scope at a time. */
  refreshSnapshot(local: string): Promise<PaletteItem[] | null> {
    const running = this.refreshing.get(local)
    if (running) return running
    const items: PaletteItem[] = []
    const run = new Promise<PaletteItem[] | null>((resolve) => {
      const id = this.openSource(local, "snapshot", "", 0, {}, (batch) => items.push(...batch), (ok) => {
        if (ok) {
          this.snapshotCache.set(local, items)
          this.dirty.delete(local)
        }
        resolve(ok ? items : null)
      })
      if (id === null) resolve(null)
    }).finally(() => this.refreshing.delete(local))
    this.refreshing.set(local, run)
    return run
  }

  /** Loads the detail of `itemId` in scope `local`. */
  detail(local: string, itemId: string): Promise<Result> {
    if (!this.vm.running) return Promise.resolve({ ok: false, error: { code: "vm.stopped", message: "the app is not running" } })
    const reqId = this.nextReq++
    this.vm.paletteRequests++
    this.inflight++
    return new Promise((resolve) => {
      this.paletteHandlers.set(reqId, { batch: () => {}, done: (ok, body) => resolve(ok ? { ok: true, value: body } : { ok: false, error: body }) })
      this.host.paletteDetail(local, itemId, reqId)
    })
  }

  /** The palette: `open(scope)` returns a session at that scope above the root (Cmd-Shift-A style); `open()` opens the root. */
  readonly palette = {
    open: async (scope?: string, options: { query?: string } = {}): Promise<PaletteSession> => {
      const session = new PaletteSession(this)
      this.sessions.add(session)
      session.start(scope === undefined ? null : scope.startsWith("app:") || scope === "actions" ? scope : this.fullScopeID(scope), options.query ?? "")
      await this.idle()
      return session
    }
  }

  /** Commands as the CLI and MCP see them: `h.commands.run("new", {title})`. */
  readonly commands = {
    run: (id: string, args: Record<string, unknown> = {}) => this.runCommand(id, args)
  }
}

export const harness = {
  /** Loads the app in `dir` (cmux-app.json + built main). Snapshot scopes are warmed unless `warm: false`. */
  async load(dir: string, options: HarnessOptions = {}): Promise<AppHarness> {
    const h = new AppHarness(dir, options)
    if (options.warm !== false) {
      for (const [id, s] of h.scopes) if (s.source.kind === "snapshot") await h.refreshSnapshot(id)
      await h.idle()
    }
    return h
  }
}
