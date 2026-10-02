// TypeScript port of the palette navigation reducer:
// Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Scopes/PaletteNav*.swift and
// PaletteScopeGraph.swift. Same events, effects, rules and invariants
// (plans/cmux-next/palette-scopes.md section 4). The shared vectors in
// ../palette-nav-vectors.json run against both implementations, so a change
// here needs the same change in Swift (and the reverse).

export type ScopeID = string
export const ROOT: ScopeID = "root"

/** Where the prefix, the keyword and the scope row enter a scope. */
export type Parents = { kind: "root" } | { kind: "anywhere" } | { kind: "only"; set: ReadonlySet<ScopeID> }

export const parentsAllow = (p: Parents, parent: ScopeID): boolean => (p.kind === "root" ? parent === ROOT : p.kind === "anywhere" ? true : p.set.has(parent))

export interface ScopeDescriptor {
  id: ScopeID
  title: string
  symbol: string
  placeholder: string
  prefix: string | null
  keywords: string[]
  parents: Parents
  emptyQuerySelection: number
  openAction: string | null
  owner: string
}

export function scopeDescriptor(init: Partial<ScopeDescriptor> & { id: ScopeID }): ScopeDescriptor {
  return {
    id: init.id,
    title: init.title ?? init.id,
    symbol: init.symbol ?? "circle",
    placeholder: init.placeholder ?? "",
    prefix: init.prefix ?? null,
    keywords: (init.keywords ?? []).map((k) => k.toLowerCase()),
    parents: init.parents ?? { kind: "root" },
    emptyQuerySelection: Math.max(0, init.emptyQuerySelection ?? 0),
    openAction: init.openAction ?? null,
    owner: init.owner ?? "client"
  }
}

export type GraphProblem =
  | { problem: "reservedID"; id: ScopeID }
  | { problem: "duplicateID"; id: ScopeID }
  | { problem: "invalidPrefix"; id: ScopeID; prefix: string }
  | { problem: "prefixCollision"; id: ScopeID; with: ScopeID; prefix: string }
  | { problem: "keywordCollision"; id: ScopeID; with: ScopeID; keyword: string }

const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : null

/** Swift `String.first`: the first grapheme cluster. */
export const firstCharacter = (text: string): string | undefined => {
  if (!text) return undefined
  if (segmenter) for (const s of segmenter.segment(text)) return s.segment
  return Array.from(text)[0]
}

/** Swift `.whitespaces`: horizontal whitespace, not newlines. */
const trimWhitespace = (s: string) => s.replace(/^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu, "")

/** Every palette scope and how scopes enter each other. Pure and immutable. */
export class ScopeGraph {
  readonly root: ScopeDescriptor
  readonly scopes = new Map<ScopeID, ScopeDescriptor>()
  /** Registration order (the scope list, `palette.scopes`). */
  readonly order: ScopeID[] = []
  readonly problems: GraphProblem[] = []

  /** A later descriptor that collides with an earlier one keeps its id but loses the colliding prefix or keyword. */
  constructor(root: ScopeDescriptor, descriptors: ScopeDescriptor[]) {
    this.root = { ...root, id: ROOT, prefix: null, keywords: [], parents: { kind: "only", set: new Set() } }
    for (const d of descriptors) this.register(d)
  }

  private register(input: ScopeDescriptor) {
    const d: ScopeDescriptor = { ...input, keywords: [...input.keywords] }
    if (d.id === ROOT) {
      this.problems.push({ problem: "reservedID", id: d.id })
      return
    }
    if (this.scopes.has(d.id)) {
      this.problems.push({ problem: "duplicateID", id: d.id })
      return
    }
    const registered = this.order.map((id) => this.scopes.get(id)!)
    if (d.prefix !== null) {
      const prefix = d.prefix
      if (!ScopeGraph.isValidPrefix(prefix)) {
        this.problems.push({ problem: "invalidPrefix", id: d.id, prefix })
        d.prefix = null
      } else {
        const other = registered.find((o) => o.prefix === prefix && ScopeGraph.parentsOverlap(o.parents, d.parents))
        if (other) {
          this.problems.push({ problem: "prefixCollision", id: d.id, with: other.id, prefix })
          d.prefix = null
        }
      }
    }
    const keywords: string[] = []
    for (const keyword of d.keywords) {
      if (!keyword || keywords.includes(keyword)) continue
      const other = registered.find((o) => o.keywords.includes(keyword) && ScopeGraph.parentsOverlap(o.parents, d.parents))
      if (other) this.problems.push({ problem: "keywordCollision", id: d.id, with: other.id, keyword })
      else keywords.push(keyword)
    }
    d.keywords = keywords
    this.scopes.set(d.id, d)
    this.order.push(d.id)
  }

  /** One grapheme that is one Unicode scalar of category P* or S*. */
  static isValidPrefix(prefix: string): boolean {
    return Array.from(prefix).length === 1 && /^[\p{P}\p{S}]$/u.test(prefix)
  }

  /** Whether some parent allows both rule sets (conservative for `anywhere`). */
  static parentsOverlap(a: Parents, b: Parents): boolean {
    if (a.kind === "anywhere" || b.kind === "anywhere") return true
    if (a.kind === "root" && b.kind === "root") return true
    if (a.kind === "root" && b.kind === "only") return b.set.has(ROOT)
    if (a.kind === "only" && b.kind === "root") return a.set.has(ROOT)
    if (a.kind === "only" && b.kind === "only") return [...a.set].some((x) => b.set.has(x))
    return false
  }

  descriptor(id: ScopeID): ScopeDescriptor | undefined {
    return id === ROOT ? this.root : this.scopes.get(id)
  }

  contains(id: ScopeID): boolean {
    return id === ROOT || this.scopes.has(id)
  }

  childByPrefix(parent: ScopeID, prefix: string): ScopeDescriptor | undefined {
    for (const id of this.order) {
      const d = this.scopes.get(id)!
      if (d.prefix === prefix && parentsAllow(d.parents, parent)) return d
    }
    return undefined
  }

  childByKeyword(parent: ScopeID, text: string): ScopeDescriptor | undefined {
    const keyword = trimWhitespace(text).toLowerCase()
    if (!keyword) return undefined
    for (const id of this.order) {
      const d = this.scopes.get(id)!
      if (d.keywords.includes(keyword) && parentsAllow(d.parents, parent)) return d
    }
    return undefined
  }

  canEnter(child: ScopeID, parent: ScopeID): boolean {
    const d = this.scopes.get(child)
    return d ? parentsAllow(d.parents, parent) : false
  }

  children(parent: ScopeID): ScopeDescriptor[] {
    return this.order.map((id) => this.scopes.get(id)!).filter((d) => parentsAllow(d.parents, parent))
  }
}

// MARK: State

export type Entry =
  | { entry: "root" }
  | { entry: "opened" }
  | { entry: "prefix"; value: string }
  | { entry: "keyword"; value: string }
  | { entry: "row"; value: string }
  | { entry: "drill"; value: string }
  | { entry: "command"; value: string | null }

/** Entered inside this palette session (Escape pops it). */
export const isPushed = (e: Entry) => e.entry !== "root" && e.entry !== "opened"

export interface NavRow {
  id: string
  enters?: ScopeID | null
  drills?: ScopeID | null
  isEnabled?: boolean
}

export interface NavLevel {
  readonly id: number
  readonly scope: ScopeID
  readonly entry: Entry
  query: string
  generation: number
  rows: NavRow[]
  rowsGeneration: number
  isLoading: boolean
  selection: string | null
  pendingReset: boolean
  pendingSubmit: boolean
}

export interface NavState {
  isOpen: boolean
  levels: NavLevel[]
  nextLevelID: number
}

export const initialNavState = (): NavState => ({ isOpen: false, levels: [], nextLevelID: 1 })

export const rowsAreCurrent = (l: NavLevel) => l.rowsGeneration === l.generation

/** The drill or scope row this level was entered from. */
export const levelContext = (l: NavLevel): string | null =>
  l.entry.entry === "drill" || l.entry.entry === "row" || l.entry.entry === "command" ? l.entry.value : null

const newLevel = (id: number, scope: ScopeID, entry: Entry, query: string): NavLevel => ({
  id,
  scope,
  entry,
  query,
  generation: 1,
  rows: [],
  rowsGeneration: 0,
  isLoading: true,
  selection: null,
  pendingReset: true,
  pendingSubmit: false
})

// MARK: Events and effects (same case names as PaletteNavEvent / PaletteNavEffect)

export type NavEvent =
  | { event: "open"; scope: ScopeID | null; query: string }
  | { event: "close" }
  | { event: "setQuery"; text: string }
  | { event: "backspaceOnEmpty" }
  | { event: "tab" }
  | { event: "shiftTab" }
  | { event: "escape" }
  | { event: "popTo"; index: number }
  | { event: "activate"; rowID: string | null }
  | { event: "push"; scope: ScopeID; row: string | null }
  | { event: "move"; delta: number }
  | { event: "select"; rowID: string }
  | { event: "results"; levelID: number; generation: number; rows: NavRow[]; replace: boolean; isFinal: boolean }
  | { event: "refresh" }

export type NavEffect =
  | { effect: "load"; levelID: number; scope: ScopeID; query: string; generation: number; context: string | null }
  | { effect: "cancel"; levelID: number }
  | { effect: "run"; levelID: number; rowID: string }
  | { effect: "openActions"; rowID: string }
  | { effect: "dismiss" }
  | { effect: "announceEntered"; scope: ScopeID }
  | { effect: "announceLeft"; to: ScopeID }
  | { effect: "refused"; reason: "depthLimit" }
  | { effect: "refused"; reason: "unknownScope"; scope: ScopeID }

export interface NavConfig {
  prefixEntry: boolean
  keywordEntry: boolean
  maxDepth: number
}

export const navConfig = (c: Partial<NavConfig> = {}): NavConfig => ({
  prefixEntry: c.prefixEntry ?? true,
  keywordEntry: c.keywordEntry ?? true,
  maxDepth: Math.max(2, c.maxDepth ?? 8)
})

const unique = (rows: NavRow[]): NavRow[] => {
  const seen = new Set<string>()
  return rows.filter((r) => (seen.has(r.id) ? false : (seen.add(r.id), true)))
}

const enabled = (r: NavRow) => r.isEnabled !== false

/** `(state, event) -> effects`, mutating `state` in place. Pure apart from that. */
export class NavReducer {
  constructor(
    public graph: ScopeGraph,
    public config: NavConfig = navConfig()
  ) {}

  reduce(state: NavState, event: NavEvent): NavEffect[] {
    if (event.event === "open") return this.open(state, event.scope, event.query)
    if (event.event === "close") return this.close(state)
    if (!state.isOpen || state.levels.length === 0) return []
    const top = state.levels.length - 1
    switch (event.event) {
      case "setQuery":
        return this.setQuery(state, event.text)
      case "backspaceOnEmpty":
        if (state.levels[top]!.query !== "") return []
        return this.pop(state, top - 1)
      case "tab":
        return this.tab(state)
      case "shiftTab":
        return this.pop(state, top - 1)
      case "escape":
        return this.escape(state)
      case "popTo":
        return this.pop(state, event.index)
      case "activate":
        return this.activate(state, event.rowID)
      case "push":
        return this.push(state, event.scope, { entry: "command", value: event.row }, "")
      case "move":
        this.move(state, event.delta)
        return []
      case "select":
        if (state.levels[top]!.rows.some((r) => r.id === event.rowID)) state.levels[top]!.selection = event.rowID
        return []
      case "results":
        return this.accept(state, event.levelID, event.generation, event.rows, event.replace, event.isFinal)
      case "refresh":
        return [this.reload(state.levels[top]!)]
    }
  }

  // Open and close

  private open(state: NavState, scope: ScopeID | null, query: string): NavEffect[] {
    const effects = this.close(state)
    state.isOpen = true
    const target = scope === null || scope === ROOT ? null : scope
    const known = target !== null && this.graph.contains(target)
    // An unknown scope opens the root with the query, and says why.
    effects.push(...this.push(state, ROOT, { entry: "root" }, known ? "" : query, false))
    if (target === null) return effects
    if (!known) return [...effects, { effect: "refused", reason: "unknownScope", scope: target }]
    effects.push(...this.push(state, target, { entry: "opened" }, query, true))
    return effects
  }

  private close(state: NavState): NavEffect[] {
    const effects: NavEffect[] = [...state.levels].reverse().map((l) => ({ effect: "cancel", levelID: l.id }))
    state.levels = []
    state.isOpen = false
    return effects
  }

  // Stack

  private push(state: NavState, scope: ScopeID, entry: Entry, query: string, announce = true): NavEffect[] {
    if (state.levels.length >= this.config.maxDepth) return [{ effect: "refused", reason: "depthLimit" }]
    if (entry.entry !== "command" && !this.graph.contains(scope)) return [{ effect: "refused", reason: "unknownScope", scope }]
    const level = newLevel(state.nextLevelID, scope, entry, query)
    state.nextLevelID += 1
    state.levels.push(level)
    const effects: NavEffect[] = [this.load(level)]
    if (announce) effects.push({ effect: "announceEntered", scope })
    return effects
  }

  /** Pops every level above `index` (at least the root stays). The new top shows its cached rows, keeps its selection and reloads. */
  private pop(state: NavState, index: number): NavEffect[] {
    const keep = Math.max(0, index) + 1
    if (keep >= state.levels.length) return []
    const effects: NavEffect[] = []
    while (state.levels.length > keep) effects.push({ effect: "cancel", levelID: state.levels.pop()!.id })
    const top = state.levels[state.levels.length - 1]!
    top.pendingSubmit = false
    effects.push(this.reload(top))
    effects.push({ effect: "announceLeft", to: top.scope })
    return effects
  }

  // Keys

  private setQuery(state: NavState, text: string): NavEffect[] {
    const level = state.levels[state.levels.length - 1]!
    if (level.query === text) return []
    const first = firstCharacter(text)
    if (this.config.prefixEntry && level.query === "" && first !== undefined && state.levels.length < this.config.maxDepth) {
      const child = this.graph.childByPrefix(level.scope, first)
      if (child) return this.push(state, child.id, { entry: "prefix", value: first }, text.slice(first.length))
    }
    return [this.edit(level, text)]
  }

  private tab(state: NavState): NavEffect[] {
    const level = state.levels[state.levels.length - 1]!
    if (this.config.keywordEntry && state.levels.length < this.config.maxDepth) {
      const child = this.graph.childByKeyword(level.scope, level.query)
      if (child) {
        const keyword = trimWhitespace(level.query).toLowerCase()
        // The keyword is consumed: the parent comes back with an empty query (reloaded when the child pops).
        level.query = ""
        level.generation += 1
        level.pendingReset = true
        level.pendingSubmit = false
        level.isLoading = true
        return this.push(state, child.id, { entry: "keyword", value: keyword }, "")
      }
    }
    const row = this.selectedRow(level)
    if (!row) return []
    if (row.enters && this.graph.contains(row.enters)) return this.push(state, row.enters, { entry: "row", value: row.id }, "")
    if (row.drills && this.graph.contains(row.drills)) return this.push(state, row.drills, { entry: "drill", value: row.id }, "")
    return enabled(row) ? [{ effect: "openActions", rowID: row.id }] : []
  }

  private escape(state: NavState): NavEffect[] {
    const top = state.levels.length - 1
    const level = state.levels[top]!
    if (isPushed(level.entry)) return this.pop(state, top - 1)
    if (level.query !== "") return [this.edit(level, "")]
    return [...this.close(state), { effect: "dismiss" }]
  }

  private activate(state: NavState, rowID: string | null): NavEffect[] {
    const level = state.levels[state.levels.length - 1]!
    if (rowID !== null) {
      if (!level.rows.some((r) => r.id === rowID)) return []
      level.selection = rowID
    } else if (!rowsAreCurrent(level)) {
      // The rows on screen belong to an older query.
      level.pendingSubmit = true
      return []
    }
    const row = this.selectedRow(level)
    if (!row) return []
    if (row.enters && this.graph.contains(row.enters)) return this.push(state, row.enters, { entry: "row", value: row.id }, "")
    return enabled(row) ? [{ effect: "run", levelID: level.id, rowID: row.id }] : []
  }

  private move(state: NavState, delta: number) {
    const level = state.levels[state.levels.length - 1]!
    const rows = level.rows
    if (rows.length === 0) return
    const current = rows.findIndex((r) => r.id === level.selection)
    const next = (((current + delta) % rows.length) + rows.length) % rows.length
    level.selection = rows[next]!.id
  }

  // Results

  private accept(state: NavState, levelID: number, generation: number, rows: NavRow[], replace: boolean, isFinal: boolean): NavEffect[] {
    const index = state.levels.findIndex((l) => l.id === levelID)
    if (index < 0 || state.levels[index]!.generation !== generation) return []
    const level = state.levels[index]!
    const previous = level.selection === null ? -1 : level.rows.findIndex((r) => r.id === level.selection)
    level.rows = replace || level.rowsGeneration !== generation ? unique(rows) : unique([...level.rows, ...rows])
    level.rowsGeneration = generation
    level.isLoading = !isFinal
    if (level.pendingReset) {
      level.selection = this.defaultSelection(level)
      level.pendingReset = false
    } else if (level.selection !== null && level.rows.some((r) => r.id === level.selection)) {
      // Kept by id.
    } else if (previous >= 0 && level.rows.length > 0) {
      level.selection = level.rows[Math.min(previous, level.rows.length - 1)]!.id
    } else {
      level.selection = this.defaultSelection(level)
    }
    const submit = level.pendingSubmit && index === state.levels.length - 1
    level.pendingSubmit = false
    return submit ? this.activate(state, null) : []
  }

  private defaultSelection(level: NavLevel): string | null {
    if (level.rows.length === 0) return null
    const preferred = level.query === "" ? (this.graph.descriptor(level.scope)?.emptyQuerySelection ?? 0) : 0
    return level.rows[Math.min(preferred, level.rows.length - 1)]!.id
  }

  // Helpers

  private edit(level: NavLevel, text: string): NavEffect {
    level.query = text
    level.pendingReset = true
    level.pendingSubmit = false
    return this.reload(level)
  }

  /** New generation for the same level; the rows on screen stay until its first batch lands. */
  private reload(level: NavLevel): NavEffect {
    level.generation += 1
    level.isLoading = true
    return this.load(level)
  }

  private load(level: NavLevel): NavEffect {
    return { effect: "load", levelID: level.id, scope: level.scope, query: level.query, generation: level.generation, context: levelContext(level) }
  }

  private selectedRow(level: NavLevel): NavRow | undefined {
    if (level.selection === null) return undefined
    return level.rows.find((r) => r.id === level.selection)
  }
}
