// Runs one case of palette-nav-vectors.json (format: ../README.md) against the
// TypeScript reducer and returns the observed values next to the expected ones.

import { initialNavState, levelContext, NavReducer, navConfig, ROOT, ScopeGraph, scopeDescriptor, type NavEffect, type NavEvent, type NavRow, type NavState, type Parents } from "./nav.ts"

export interface VectorScope {
  id: string
  prefix?: string | null
  keywords?: string[]
  parents?: "root" | "anywhere" | string[]
  emptyQuerySelection?: number
}

export type VectorStep = (NavEvent & { answer?: boolean }) | { driver: "setRows"; scope: string; rows: NavRow[] }

export interface VectorCase {
  name: string
  rule?: string
  config?: { prefixEntry?: boolean; keywordEntry?: boolean; maxDepth?: number }
  graph: { rootEmptyQuerySelection?: number; scopes: VectorScope[] }
  rowsByScope: Record<string, NavRow[]>
  events: VectorStep[]
  expect: VectorExpect
}

export interface VectorExpect {
  isOpen: boolean
  chips: string[]
  query: string | null
  selection: string | null
  queries?: string[]
  selections?: Array<string | null>
  topEntry?: { entry: string; value?: string | null }
  topRows?: string[]
  topContext?: string | null
  isLoading?: boolean
  graphProblems?: number
  lastEffects?: NavEffect[]
  lastEffectsInclude?: NavEffect[]
}

const parents = (p: VectorScope["parents"]): Parents => (p === undefined || p === "root" ? { kind: "root" } : p === "anywhere" ? { kind: "anywhere" } : { kind: "only", set: new Set(p) })

export function graphOf(c: VectorCase): ScopeGraph {
  return new ScopeGraph(
    scopeDescriptor({ id: ROOT, emptyQuerySelection: c.graph.rootEmptyQuerySelection ?? 0 }),
    c.graph.scopes.map((s) => scopeDescriptor({ id: s.id, prefix: s.prefix ?? null, keywords: s.keywords ?? [], parents: parents(s.parents), emptyQuerySelection: s.emptyQuerySelection ?? 0 }))
  )
}

/** Normalizes a row the way the JSON carries it: missing fields are absent. */
const normalizeRow = (r: NavRow): NavRow => ({ id: r.id, enters: r.enters ?? null, drills: r.drills ?? null, isEnabled: r.isEnabled !== false })

/** The PaletteNavDriver of the Swift tests: answers every `load` with the scope's fixed rows. */
export class NavDriver {
  readonly state: NavState = initialNavState()
  readonly reducer: NavReducer
  rowsByScope: Map<string, NavRow[]>
  constructor(c: VectorCase) {
    this.reducer = new NavReducer(graphOf(c), navConfig(c.config ?? {}))
    this.rowsByScope = new Map(Object.entries(c.rowsByScope).map(([k, v]) => [k, v.map(normalizeRow)]))
  }

  send(event: NavEvent, answer = true): NavEffect[] {
    const e = event.event === "results" ? { ...event, rows: event.rows.map(normalizeRow) } : event
    const produced = this.reducer.reduce(this.state, e)
    if (!answer) return produced
    const all = [...produced]
    for (const effect of produced) {
      if (effect.effect !== "load") continue
      all.push(...this.send({ event: "results", levelID: effect.levelID, generation: effect.generation, rows: this.rowsByScope.get(effect.scope) ?? [], replace: true, isFinal: true }))
    }
    return all
  }
}

export interface VectorOutcome {
  actual: Record<string, unknown>
  expected: Record<string, unknown>
}

/** Runs the case; `actual` holds the same keys as `expect` (lastEffectsInclude reports the effects it found). */
export function runVector(c: VectorCase): VectorOutcome {
  const driver = new NavDriver(c)
  let last: NavEffect[] = []
  for (const step of c.events) {
    if ("driver" in step) {
      driver.rowsByScope.set(step.scope, step.rows.map(normalizeRow))
      continue
    }
    const { answer, ...event } = step as NavEvent & { answer?: boolean }
    last = driver.send(event as NavEvent, answer !== false)
  }
  const s = driver.state
  const top = s.levels.at(-1)
  const actual: Record<string, unknown> = {
    isOpen: s.isOpen,
    chips: s.levels.map((l) => l.scope),
    query: top?.query ?? null,
    selection: top?.selection ?? null
  }
  const e = c.expect
  if (e.queries) actual.queries = s.levels.map((l) => l.query)
  if (e.selections) actual.selections = s.levels.map((l) => l.selection)
  if (e.topEntry) actual.topEntry = top ? ("value" in top.entry ? { entry: top.entry.entry, value: top.entry.value } : { entry: top.entry.entry }) : null
  if (e.topRows) actual.topRows = top?.rows.map((r) => r.id) ?? []
  if ("topContext" in e) actual.topContext = top ? levelContext(top) : null
  if ("isLoading" in e) actual.isLoading = top?.isLoading ?? false
  if ("graphProblems" in e) actual.graphProblems = driver.reducer.graph.problems.length
  if (e.lastEffects) actual.lastEffects = last
  if (e.lastEffectsInclude) {
    const json = last.map((x) => JSON.stringify(x))
    actual.lastEffectsInclude = e.lastEffectsInclude.filter((x) => json.includes(JSON.stringify(x)))
  }
  return { actual, expected: e as unknown as Record<string, unknown> }
}

/** Invariants I1 to I4 of palette-scopes.md section 4.4 on a state (used by the random tests). */
export function invariantViolations(s: NavState, maxDepth: number): string[] {
  const v: string[] = []
  if (s.isOpen) {
    if (s.levels.length === 0) v.push("I1: open with no levels")
    else if (s.levels[0]!.scope !== ROOT || s.levels[0]!.entry.entry !== "root") v.push("I1: level 0 is not the root")
    if (s.levels.slice(1).some((l) => l.entry.entry === "root")) v.push("I1: root entry above level 0")
  } else if (s.levels.length) v.push("I1: closed with levels")
  if (s.levels.length > maxDepth) v.push("I2: too deep")
  for (let i = 1; i < s.levels.length; i++) if (s.levels[i]!.id <= s.levels[i - 1]!.id) v.push("I2: ids not increasing")
  for (const l of s.levels) {
    if (l.selection !== null && !l.rows.some((r) => r.id === l.selection)) v.push(`I3: selection ${l.selection} not a row of level ${l.id}`)
    if (l.rowsGeneration === l.generation && l.rows.length && l.selection === null) v.push(`I3: level ${l.id} has current rows and no selection`)
    if (l.rowsGeneration > l.generation) v.push("I4: rowsGeneration > generation")
    if (l.entry.entry === "opened" && s.levels.indexOf(l) !== 1) v.push("I5: opened level not at index 1")
  }
  return v
}
