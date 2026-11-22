// A fake app host for tests: loads the built runtime and an app script into a
// fresh node:vm context and implements __cmuxAppNative in memory.
import { readFileSync } from "node:fs"
import vm from "node:vm"

const runtimeSource = readFileSync(new URL("../dist/cmux-app-runtime.js", import.meta.url), "utf8")

export type Op = { op: string; id: string; type?: string; props?: Record<string, unknown>; children?: string[] }
export type OpHandler = (params: any, options: any) => { ok: boolean; body: unknown } | Promise<{ ok: boolean; body: unknown }>
export type PaletteBatch = { reqId: number; generation: number; items: any[]; isFinal: boolean; replace: boolean }

export class FakeHost {
  readonly ctx: vm.Context
  readonly scenes = new Map<string, Op[][]>()
  readonly logs: Array<[string, string]> = []
  readonly calls: Array<{ name: string; params: any; options: any }> = []
  readonly subscriptions = new Map<number, { stream: string; filter: any }>()
  readonly timers = new Map<number, { ms: number; repeat: boolean }>()
  readonly commandResults = new Map<number, { ok: boolean; body: any }>()
  readonly paletteBatches: PaletteBatch[] = []
  readonly paletteResults = new Map<number, { ok: boolean; body: any }>()
  handlers: Record<string, OpHandler> = {}
  /** Answers ops with no entry in `handlers` (default: operation.unsupported). */
  fallback?: (name: string, params: any, options: any) => { ok: boolean; body: unknown } | Promise<{ ok: boolean; body: unknown }>
  /** Observers for hosts built on this one (the @cmux/app-test harness). */
  onPaletteBatch?: (batch: PaletteBatch) => void
  onPaletteDone?: (reqId: number, ok: boolean, body: any) => void
  onCommandDone?: (cbId: number, ok: boolean, body: any) => void
  private nextSub = 1
  private nextTimer = 1

  constructor(appSource = "", init: Record<string, unknown> = { app: { id: "local/test", version: "1.0.0" }, apiVersion: "1.0.0" }) {
    const host = this
    const native = {
      call(name: string, paramsJSON: string, optionsJSON: string, cbId: number) {
        const params = JSON.parse(paramsJSON)
        const options = JSON.parse(optionsJSON)
        host.calls.push({ name, params, options })
        const h = host.handlers[name]
        const reply = (r: { ok: boolean; body: unknown }) => host.global.__cmuxAppResolve(cbId, r.ok, JSON.stringify(r.body))
        if (!h) {
          if (host.fallback) {
            Promise.resolve(host.fallback(name, params, options)).then(reply)
            return
          }
          queueMicrotask(() => reply({ ok: false, body: { code: "operation.unsupported", message: `no handler for ${name}`, retryable: false } }))
          return
        }
        Promise.resolve(h(params, options)).then(reply)
      },
      subscribe(stream: string, filterJSON: string) {
        const id = host.nextSub++
        host.subscriptions.set(id, { stream, filter: JSON.parse(filterJSON) })
        return id
      },
      unsubscribe(id: number) {
        host.subscriptions.delete(id)
      },
      scene(mountId: string, opsJSON: string) {
        const list = host.scenes.get(mountId) ?? []
        list.push(JSON.parse(opsJSON))
        host.scenes.set(mountId, list)
      },
      timer(ms: number, repeat: boolean) {
        const id = host.nextTimer++
        host.timers.set(id, { ms, repeat })
        return id
      },
      clearTimer(id: number) {
        host.timers.delete(id)
      },
      log(level: string, message: string) {
        host.logs.push([level, message])
      },
      commandDone(cbId: number, ok: boolean, json: string) {
        const body = JSON.parse(json)
        host.commandResults.set(cbId, { ok, body })
        host.onCommandDone?.(cbId, ok, body)
      },
      paletteBatch(reqId: number, generation: number, itemsJSON: string, isFinal: boolean, replace: boolean) {
        const batch = { reqId, generation, items: JSON.parse(itemsJSON), isFinal, replace }
        host.paletteBatches.push(batch)
        host.onPaletteBatch?.(batch)
      },
      paletteDone(reqId: number, ok: boolean, json: string) {
        const body = JSON.parse(json)
        host.paletteResults.set(reqId, { ok, body })
        host.onPaletteDone?.(reqId, ok, body)
      }
    }
    this.ctx = vm.createContext({ __cmuxAppNative: native, queueMicrotask })
    vm.runInContext(runtimeSource, this.ctx)
    if (appSource) vm.runInContext(appSource, this.ctx)
    this.global.__cmuxAppInit(JSON.stringify(init))
  }

  get global(): any {
    return this.ctx as any
  }

  eval(source: string): any {
    return vm.runInContext(source, this.ctx)
  }

  /** Lets promise continuations (and the flushes they schedule) run. */
  async settle(rounds = 5) {
    for (let i = 0; i < rounds; i++) await new Promise((r) => setImmediate(r))
  }

  batches(mountId: string): Op[][] {
    return this.scenes.get(mountId) ?? []
  }

  lastBatch(mountId: string): Op[] {
    const b = this.batches(mountId)
    return b[b.length - 1] ?? []
  }

  /** Applies every batch to a tree and returns it (a reference scene store). */
  tree(mountId: string) {
    const nodes = new Map<string, { type: string; props: Record<string, unknown>; children: string[] }>()
    let root = ""
    for (const batch of this.batches(mountId)) {
      for (const op of batch) {
        if (op.op === "create") nodes.set(op.id, { type: op.type!, props: { ...op.props }, children: [] })
        else if (op.op === "update") {
          const n = nodes.get(op.id)!
          for (const [k, v] of Object.entries(op.props!)) if (v === null) delete n.props[k]; else n.props[k] = v
        } else if (op.op === "children") nodes.get(op.id)!.children = op.children!
        else if (op.op === "remove") nodes.delete(op.id)
        else if (op.op === "root") root = op.id
      }
    }
    return { root, nodes }
  }

  mount(mountId: string, exportName: string, ctx: Record<string, unknown> = {}) {
    return this.global.__cmuxAppMount(mountId, exportName, JSON.stringify(ctx))
  }

  dispatch(mountId: string, nodeId: string, event: string, payload: unknown = {}) {
    this.global.__cmuxAppDispatch(mountId, nodeId, event, JSON.stringify(payload))
  }

  /** Runs a command export; `ctx` is the invocation context (`{gesture}`). */
  runCommand(exportName: string, args: unknown = {}, cbId = 1, ctx?: Record<string, unknown>) {
    this.global.__cmuxAppRunCommand(exportName, JSON.stringify(args), cbId, ctx ? JSON.stringify(ctx) : undefined)
  }

  paletteOpen(scope: string, kind: "snapshot" | "query", query: string, generation: number, reqId: number, ctx: Record<string, unknown> = {}): string {
    return this.global.__cmuxAppPaletteOpen(scope, kind, query, generation, JSON.stringify(ctx), reqId)
  }

  paletteCancel(reqId: number) {
    this.global.__cmuxAppPaletteCancel(reqId)
  }

  paletteDetail(scope: string, itemId: string, reqId: number) {
    this.global.__cmuxAppPaletteDetail(scope, itemId, reqId)
  }

  batchesFor(reqId: number): PaletteBatch[] {
    return this.paletteBatches.filter((b) => b.reqId === reqId)
  }

  emit(stream: string, payload: unknown = {}) {
    for (const [id, s] of this.subscriptions) if (s.stream === stream) this.global.__cmuxAppEvent(id, JSON.stringify(payload))
  }

  findNode(mountId: string, pred: (n: { type: string; props: Record<string, unknown> }) => boolean): string | undefined {
    for (const [id, n] of this.tree(mountId).nodes) if (pred(n)) return id
    return undefined
  }
}

/** Wraps app code in the IIFE shape `cmux app pack` produces. */
export const app = (body: string) => `var __cmuxAppExports = (() => { ${body} })();`
