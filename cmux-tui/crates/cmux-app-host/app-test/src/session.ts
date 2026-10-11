// One open palette in the harness: the navigation reducer (nav.ts) plus the
// host's half of the scope protocol. It answers `load` effects from the
// snapshot cache (no VM), from query sources in the VM (streamed batches),
// from op sources (fixtures), the root's scope and command rows, and the
// `actions` drill scope; it runs `run` effects as ActionRefs.

import type { ActionRef, AppHarness, PaletteItem, ScopeDecl } from "./index.ts"
import { localized } from "./index.ts"
import { initialNavState, NavReducer, ROOT, ScopeGraph, scopeDescriptor, type NavEffect, type NavEvent, type NavLevel, type NavRow, type Parents } from "./nav.ts"
import { rank } from "./rank.ts"

export interface SessionRow {
  id: string
  title: string
  subtitle?: string
  symbol?: string
  kind: "scope" | "command" | "item" | "action"
}

interface Display extends SessionRow {
  enters?: string
  drills?: string
  item?: PaletteItem
  ref?: ActionRef
  command?: string
}

const ACTIONS = "actions"

const segments = (s: string) => Array.from(s)

/** JSONPath-lite: `$`, `$.a.b`, `$.tags[0]`. */
export function pick(value: unknown, path: string): unknown {
  if (path === "$") return value
  if (!path.startsWith("$")) return undefined
  let cur: unknown = value
  for (const m of path.slice(1).matchAll(/\.([A-Za-z_][A-Za-z0-9_]*)|\[(\d+)\]/g)) {
    if (cur === null || typeof cur !== "object") return undefined
    cur = m[1] !== undefined ? (cur as Record<string, unknown>)[m[1]] : (cur as unknown[])[Number(m[2])]
  }
  return cur
}

export class PaletteSession {
  private readonly reducer: NavReducer
  private readonly state = initialNavState()
  private readonly display = new Map<number, Map<string, Display>>()
  private readonly requests = new Map<number, number>()
  private t0 = 0
  /** Milliseconds from `open` to the first rows of the opened scope. */
  firstPaintMs: number | null = null
  /** Every effect the reducer emitted, in order. */
  readonly effects: NavEffect[] = []
  /** ActionRefs and commands this session ran (Return, click). */
  readonly ran: ActionRef[] = []
  /** The row whose Actions menu Tab opened (Tab with nothing to enter). */
  actionsMenu: string | null = null
  /** Source failures: `{scope, code, message}`. */
  readonly errors: Array<{ scope: string; code: string; message: string }> = []

  constructor(private readonly h: AppHarness) {
    const scopes = [...h.scopes.values()]
    const parentsOf = new Map<string, Set<string>>()
    for (const s of scopes) for (const child of s.children ?? []) {
      const id = child.startsWith("app:") ? child : h.fullScopeID(child)
      if (!parentsOf.has(id)) parentsOf.set(id, new Set([ROOT]))
      parentsOf.get(id)!.add(h.fullScopeID(s.id))
    }
    const parents = (id: string): Parents => (parentsOf.has(id) ? { kind: "only", set: parentsOf.get(id)! } : { kind: "root" })
    this.reducer = new NavReducer(
      new ScopeGraph(scopeDescriptor({ id: ROOT, title: "cmux" }), [
        ...scopes.map((s) => {
          const id = h.fullScopeID(s.id)
          return scopeDescriptor({ id, title: localized(s.title, s.id), symbol: s.symbol, prefix: s.prefix ?? null, keywords: s.keywords ?? [], parents: parents(id), owner: `app:${h.appId}` })
        }),
        scopeDescriptor({ id: ACTIONS, title: "Actions", parents: { kind: "only", set: new Set() } })
      ])
    )
  }

  // MARK: Reading

  get isOpen() {
    return this.state.isOpen
  }

  private get top(): NavLevel | undefined {
    return this.state.levels.at(-1)
  }

  /** Chip titles above the root, root first ([] at the root). */
  get chips(): string[] {
    return this.state.levels.slice(1).map((l) => this.reducer.graph.descriptor(l.scope)?.title ?? l.scope)
  }

  /** Scope ids of every level including the root. */
  get scopePath(): string[] {
    return this.state.levels.map((l) => l.scope)
  }

  get query(): string {
    return this.top?.query ?? ""
  }

  get selection(): string | null {
    return this.top?.selection ?? null
  }

  get isLoading(): boolean {
    return this.top?.isLoading ?? false
  }

  get rows(): SessionRow[] {
    const top = this.top
    if (!top) return []
    const display = this.display.get(top.id)
    return top.rows.map((r) => {
      const d = display?.get(r.id)
      return d ? { id: d.id, title: d.title, kind: d.kind, ...(d.subtitle ? { subtitle: d.subtitle } : {}), ...(d.symbol ? { symbol: d.symbol } : {}) } : { id: r.id, title: r.id, kind: "item" as const }
    })
  }

  // MARK: Keys

  async type(text: string) {
    for (const ch of segments(text)) this.dispatch({ event: "setQuery", text: this.query + ch })
    await this.h.idle()
  }

  async backspace() {
    if (this.query === "") this.dispatch({ event: "backspaceOnEmpty" })
    else this.dispatch({ event: "setQuery", text: segments(this.query).slice(0, -1).join("") })
    await this.h.idle()
  }

  async tab() {
    this.dispatch({ event: "tab" })
    await this.h.idle()
  }

  async shiftTab() {
    this.dispatch({ event: "shiftTab" })
    await this.h.idle()
  }

  async escape() {
    this.dispatch({ event: "escape" })
    await this.h.idle()
  }

  async press(key: "Return" | "Up" | "Down" | "Tab" | "Escape") {
    if (key === "Tab") return this.tab()
    if (key === "Escape") return this.escape()
    this.dispatch(key === "Return" ? { event: "activate", rowID: null } : { event: "move", delta: key === "Up" ? -1 : 1 })
    await this.h.idle()
  }

  async click(rowID: string) {
    this.dispatch({ event: "activate", rowID })
    await this.h.idle()
  }

  select(rowID: string) {
    this.dispatch({ event: "select", rowID })
  }

  /** Detail of the selected row (listWithDetail scopes). */
  async detail() {
    const top = this.top
    const local = top ? this.localScope(top.scope) : undefined
    if (!top || !local || !top.selection) return null
    const r = await this.h.detail(local, top.selection)
    await this.h.idle()
    return r.ok ? r.value : Promise.reject(Object.assign(new Error(r.error.message), r.error))
  }

  close() {
    this.dispatch({ event: "close" })
    this.h.sessions.delete(this)
  }

  // MARK: Driving

  start(scope: string | null, query: string) {
    this.t0 = performance.now()
    this.dispatch({ event: "open", scope, query })
  }

  /** An event invalidated `scope`: refresh it when it is on top. */
  invalidated(scope: string) {
    if (this.top?.scope === scope) this.dispatch({ event: "refresh" })
  }

  private dispatch(event: NavEvent) {
    const effects = this.reducer.reduce(this.state, event)
    this.effects.push(...effects)
    for (const e of effects) this.perform(e)
  }

  private perform(e: NavEffect) {
    switch (e.effect) {
      case "load":
        return this.load(e)
      case "cancel": {
        const req = this.requests.get(e.levelID)
        if (req !== undefined) this.h.cancelSource(req)
        this.requests.delete(e.levelID)
        this.display.delete(e.levelID)
        return
      }
      case "run":
        return this.run(e.levelID, e.rowID)
      case "openActions":
        this.actionsMenu = e.rowID
        return
      case "dismiss":
        this.h.sessions.delete(this)
        return
      default:
        return
    }
  }

  private answer(levelID: number, generation: number, rows: Display[], isFinal: boolean, replace = true) {
    const level = this.state.levels.find((l) => l.id === levelID)
    if (!level || level.generation !== generation) return
    let display = this.display.get(levelID)
    if (!display || replace) this.display.set(levelID, (display = new Map()))
    for (const r of rows) display.set(r.id, r)
    const nav: NavRow[] = rows.map((r) => ({ id: r.id, enters: r.enters ?? null, drills: r.drills ?? null }))
    this.dispatch({ event: "results", levelID, generation, rows: nav, replace, isFinal })
    // The reducer pushes every level of `open` before its loads run, so the first answer for the top level is the opened scope's.
    if (this.firstPaintMs === null && level === this.state.levels.at(-1) && level.rowsGeneration === generation) this.firstPaintMs = performance.now() - this.t0
  }

  private localScope(scope: string): string | undefined {
    const prefix = `app:${this.h.appId}#`
    return scope.startsWith(prefix) ? scope.slice(prefix.length) : undefined
  }

  private resolveScope(id: string | undefined): string | undefined {
    if (!id) return undefined
    return id === ACTIONS || id.startsWith("app:") ? id : this.h.fullScopeID(id)
  }

  private itemRow(item: PaletteItem): Display {
    return {
      id: item.id,
      title: item.title,
      kind: "item",
      item,
      ...(item.subtitle ? { subtitle: item.subtitle } : {}),
      ...(item.symbol ? { symbol: item.symbol } : {}),
      ...(item.enters ? { enters: this.resolveScope(item.enters) } : {}),
      drills: this.resolveScope(item.drill) ?? ACTIONS
    }
  }

  private load(e: Extract<NavEffect, { effect: "load" }>) {
    if (e.scope === ROOT) return this.answer(e.levelID, e.generation, this.rootRows(e.query), true)
    if (e.scope === ACTIONS) return this.answer(e.levelID, e.generation, this.actionRows(e.levelID, e.context, e.query), true)
    const local = this.localScope(e.scope)
    const decl = local === undefined ? undefined : this.h.scopes.get(local)
    if (!decl || local === undefined) return this.answer(e.levelID, e.generation, [], true)
    if (decl.source.kind === "snapshot") return this.loadSnapshot(e, local, decl)
    if (decl.source.kind === "query") return this.loadQuery(e, local, decl)
    return this.loadOp(e, decl)
  }

  private rootRows(query: string): Display[] {
    const scopes: Display[] = [...this.h.scopes.values()].map((s) => ({ id: `scope:${s.id}`, title: localized(s.title, s.id), kind: "scope", enters: this.h.fullScopeID(s.id), keywords: s.keywords }) as Display)
    const commands: Display[] = [...this.h.commandDecls.values()]
      .filter((c) => !c.contexts || c.contexts.includes("palette"))
      .map((c) => ({ id: `command:${c.id}`, title: localized(c.title, c.id), kind: "command", command: c.id, keywords: c.keywords }) as Display)
    return rank([...scopes, ...commands] as Array<Display & { keywords?: string[] }>, query)
  }

  private actionRows(levelID: number, context: string | null, query: string): Display[] {
    const index = this.state.levels.findIndex((l) => l.id === levelID)
    const parent = index > 0 ? this.state.levels[index - 1] : undefined
    const row = parent && context ? this.display.get(parent.id)?.get(context) : undefined
    const refs = row ? this.refsOf(row) : []
    const rows = refs.map((ref, i): Display => ({ id: `action:${i}`, title: ref.title ?? this.actionTitle(ref.id), kind: "action", ref, ...(ref.symbol ? { symbol: ref.symbol } : {}) }))
    return rank(rows, query, "source")
  }

  /** The host renders an ActionRef's title from the catalog: the app's own commands by their manifest title, other actions by id here. */
  private actionTitle(id: string): string {
    const prefix = `app:${this.h.appId}#`
    const cmd = id.startsWith(prefix) ? this.h.commandDecls.get(id.slice(prefix.length)) : undefined
    return cmd ? localized(cmd.title, cmd.id) : id
  }

  /** A row's ActionRefs: its own, else the scope's `primary` with `{id}`. */
  private refsOf(row: Display): ActionRef[] {
    if (row.ref) return [row.ref]
    if (row.command) return [{ id: `app:${this.h.appId}#${row.command}`, args: {} }]
    if (!row.item) return []
    if (row.item.actions?.length) return row.item.actions
    const level = this.state.levels.find((l) => this.display.get(l.id)?.get(row.id) === row)
    const decl = level ? this.h.scopes.get(this.localScope(level.scope) ?? "") : undefined
    return decl?.primary ? [{ id: decl.primary, args: { id: row.item.id } }] : []
  }

  private loadSnapshot(e: Extract<NavEffect, { effect: "load" }>, local: string, decl: ScopeDecl) {
    const answerFromCache = (generation: number) => {
      const cached = this.h.snapshotCache.get(local) ?? []
      this.answer(e.levelID, generation, rank(cached, e.query, decl.ranking ?? "fuzzy").map((i) => this.itemRow(i)), true)
    }
    const cached = this.h.snapshotCache.has(local)
    // First paint: the supervisor's last snapshot, ranked here; no VM.
    if (cached) answerFromCache(e.generation)
    if (cached && !this.h.dirty.has(local)) return
    if (!this.h.vm.running) {
      if (!cached) {
        this.errors.push({ scope: local, code: "vm.stopped", message: "no cached snapshot and the app is not running" })
        this.answer(e.levelID, e.generation, [], true)
      }
      return
    }
    this.h.refreshSnapshot(local).then((items) => {
      const level = this.state.levels.find((l) => l.id === e.levelID)
      if (!level) return
      if (!items) this.errors.push({ scope: local, code: "snapshot.failed", message: "the snapshot source failed" })
      // Re-rank the new snapshot for the level's current query and generation.
      const current = level.query
      const fresh = this.h.snapshotCache.get(local) ?? []
      this.answer(level.id, level.generation, rank(fresh, current, decl.ranking ?? "fuzzy").map((i) => this.itemRow(i)), true)
    })
  }

  private loadQuery(e: Extract<NavEffect, { effect: "load" }>, local: string, decl: ScopeDecl) {
    const previous = this.requests.get(e.levelID)
    if (previous !== undefined) this.h.cancelSource(previous)
    this.requests.delete(e.levelID)
    if (segments(e.query).length < (decl.source.minQueryLength ?? 0)) return this.answer(e.levelID, e.generation, [], true)
    let final = false
    let any = false
    const req = this.h.openSource(
      local,
      "query",
      e.query,
      e.generation,
      { session: String(e.levelID), ...(e.context ? { context: e.context } : {}) },
      (items, isFinal, generation, replace) => {
        this.answer(e.levelID, generation, items.map((i) => this.itemRow(i)), isFinal, replace)
        any = true
        final ||= isFinal
      },
      (ok, body) => {
        if (this.requests.get(e.levelID) === req) this.requests.delete(e.levelID)
        if (ok) return
        this.errors.push({ scope: local, code: body?.code ?? "palette.failed", message: body?.message ?? "" })
        // A failed request keeps what it streamed (the cached rows when offline) and stops loading.
        if (!final) this.answer(e.levelID, e.generation, [], true, !any)
      }
    )
    if (req === null) {
      this.errors.push({ scope: local, code: "vm.stopped", message: "the app is not running" })
      return this.answer(e.levelID, e.generation, [], true)
    }
    this.requests.set(e.levelID, req)
  }

  /** `source.kind = op`: a read op (a fixture here) mapped by JSONPath-lite; no app code. */
  private loadOp(e: Extract<NavEffect, { effect: "load" }>, decl: ScopeDecl) {
    const op = decl.source.op!
    this.h.inflight++
    this.h.resolveOp(op, { query: e.query, ...(e.context ? { context: e.context } : {}) }, "script").then((reply) => {
      this.h.inflight--
      const body = reply.body as { value?: unknown; code?: string; message?: string }
      if (!reply.ok) {
        this.errors.push({ scope: decl.id, code: body.code ?? "operation.failed", message: body.message ?? "" })
        return this.answer(e.levelID, e.generation, [], true)
      }
      const list = Array.isArray(body.value) ? body.value : ((body.value as { items?: unknown[] })?.items ?? [])
      const map = decl.source.item ?? {}
      const items = list.map((raw) => Object.fromEntries(Object.entries(map).map(([k, path]) => [k, pick(raw, path)])) as PaletteItem).filter((i) => typeof i.id === "string" && typeof i.title === "string")
      this.answer(e.levelID, e.generation, rank(items, e.query, decl.ranking ?? "source").map((i) => this.itemRow(i)), true)
    })
  }

  private run(levelID: number, rowID: string) {
    const row = this.display.get(levelID)?.get(rowID)
    if (!row) return
    const ref = this.refsOf(row)[0]
    if (!ref) return
    this.ran.push(ref)
    this.h.inflight++
    this.h.runAction(ref, "user").finally(() => this.h.inflight--)
  }
}
