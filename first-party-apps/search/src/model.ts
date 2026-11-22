// Result model, ranking and grouping: pure functions.

import type { Range, Segments } from "./match.ts"
import { SOURCES, type Scope, type SourceId } from "./query.ts"

export type HitKind = "workspace" | "terminal" | "terminalText" | "browserTab" | "history" | "file" | "fileContent" | "appItem"

/** What opening a hit does. Agents get this verbatim so they can call the op themselves. */
export type Target =
  | { op: "workspace.focus"; params: { workspace: string } }
  | { op: "tab.focus"; params: { tab: string; workspace?: string }; reveal?: { terminal: string; row: string } }
  | { op: "action.run"; params: { id: string; args: Record<string, unknown> } }

export interface Hit {
  /** Stable across searches: `<kind>:<owner id>[:<detail>]`. */
  id: string
  source: SourceId
  kind: HitKind
  title: string
  /** Where the hit lives: workspace, folder, site, app. */
  location: string
  symbol: string
  /** Highlight inside the title, when the title matched. */
  titleRange: Range | null
  /** Text around a body match (terminal line, file line). */
  preview: Segments | null
  /** 0..100 from the matcher. */
  quality: number
  updatedAtMs: number | null
  workspaceId: string | null
  /** Terminal text found only on the visible screen (no transcript search yet). */
  screenOnly?: boolean
  target: Target
  score: number
}

export interface Group {
  source: SourceId
  hits: Hit[]
  /** Hits found before the per-group cap. */
  total: number
  /** The owner stopped early (its own cap), so more may exist. */
  truncated: boolean
}

export interface Unavailable {
  source: SourceId
  /** `operation.unsupported`, `scope.missing`, `no.roots`, `query.invalid`, or an owner error code. */
  code: string
  /** The op that would answer, for the "what is missing" copy. */
  op: string
}

export interface RankContext {
  nowMs: number
  scope: Scope
  currentWorkspace: string | null
  /** Hit id -> when the user last opened it from search. */
  opened: Readonly<Record<string, number>>
}

const DAY = 24 * 60 * 60 * 1000

/** 0..24, linear over the last 7 days (newer is higher). */
export function recencyBonus(ms: number | null, nowMs: number): number {
  if (!ms || !Number.isFinite(ms) || ms <= 0) return 0
  const age = Math.max(0, nowMs - ms)
  return Math.round(24 * (1 - Math.min(age, 7 * DAY) / (7 * DAY)))
}

export function score(hit: Hit, ctx: RankContext): number {
  let s = hit.quality + recencyBonus(hit.updatedAtMs, ctx.nowMs)
  if (ctx.scope === "all" && ctx.currentWorkspace && hit.workspaceId === ctx.currentWorkspace) s += 8
  const opened = ctx.opened[hit.id]
  if (opened) s += Math.round(16 * (1 - Math.min(Math.max(0, ctx.nowMs - opened), 30 * DAY) / (30 * DAY)))
  return s
}

const byRank = (a: Hit, b: Hit) => b.score - a.score || (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0) || a.title.localeCompare(b.title)

/** Merges hit lists by id, keeping the better-scored copy, and scores every hit. */
export function rank(lists: Hit[][], ctx: RankContext): Hit[] {
  const byId = new Map<string, Hit>()
  for (const list of lists) {
    for (const raw of list) {
      const hit = { ...raw, score: score(raw, ctx) }
      const prev = byId.get(hit.id)
      if (!prev || hit.score > prev.score) byId.set(hit.id, hit)
    }
  }
  return [...byId.values()].sort(byRank)
}

/** Groups ranked hits in the fixed source order and caps each group. */
export function group(hits: readonly Hit[], limitPerGroup: number, truncatedSources: ReadonlySet<SourceId> = new Set()): Group[] {
  const out: Group[] = []
  for (const source of SOURCES) {
    const members = hits.filter((h) => h.source === source)
    if (!members.length) continue
    out.push({ source, hits: members.slice(0, limitPerGroup), total: members.length, truncated: truncatedSources.has(source) || members.length > limitPerGroup })
  }
  return out
}

/** The hit Return opens: the selected one when still present, else the best. */
export function activeHit(ranked: readonly Hit[], selectedId: string | null): Hit | null {
  return (selectedId ? ranked.find((h) => h.id === selectedId) : undefined) ?? ranked[0] ?? null
}

/** Per-group caps: compact surfaces show fewer, one-source searches show many. */
export function groupLimit(density: "compact" | "full", sourceCount: number): number {
  if (sourceCount === 1) return 40
  return density === "compact" ? 4 : 8
}
