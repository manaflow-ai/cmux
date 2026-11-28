/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// One search: read the session snapshot once, match names locally, fan out to
// the owners of terminal text, history, files and app items concurrently, and
// rank and group what comes back. Partial results are reported as each source
// answers, so names show at once and slower owners fill in.

import { compile } from "./match.ts"
import { activeHit, group, groupLimit, rank, type Group, type Hit, type RankContext, type Unavailable } from "./model.ts"
import { type ParsedQuery, type Scope, type SourceId } from "./query.ts"
import { places, searchSnapshot } from "./sources/local.ts"
import { apps, files, history, terminalText, type Call, type SourceInput, type SourceResult } from "./sources/remote.ts"

export interface SearchRequest {
  query: ParsedQuery
  sources: readonly SourceId[]
  scope: Scope
  density: "compact" | "full"
  /** Total hits per remote source. */
  limit: number
  /** Prefix for the owners' `search_id` (one per surface, so a new search supersedes the old). */
  searchId: string
  opened: Readonly<Record<string, number>>
  selfId: string
  nowMs: number
}

export interface SearchResponse {
  query: string
  scope: Scope
  groups: Group[]
  /** Every hit, best first (groups hold the capped view). */
  ranked: Hit[]
  top: Hit | null
  unavailable: Unavailable[]
  truncated: boolean
  /** Sources still answering. */
  pending: SourceId[]
  currentWorkspace: string | null
  /** The regex compile error, when the query is an invalid regular expression. */
  error?: string
}

export const emptyResponse = (query: string, scope: Scope): SearchResponse => ({ query, scope, groups: [], ranked: [], top: null, unavailable: [], truncated: false, pending: [], currentWorkspace: null })

export async function runSearch(req: SearchRequest, call: Call, onPartial?: (r: SearchResponse) => void): Promise<SearchResponse> {
  const q = req.query
  if (!q.text) return emptyResponse(q.raw, req.scope)
  if (q.error) return { ...emptyResponse(q.raw, req.scope), error: q.error, unavailable: req.sources.map((source) => ({ source, op: "", code: "query.invalid" })) }

  const matcher = compile(q)
  let snapshot: Cmux.ResourceSnapshot | null = null
  const unavailable: Unavailable[] = []
  try {
    snapshot = (await call("session.snapshot", {})) as Cmux.ResourceSnapshot
  } catch (e) {
    const code = e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "operation.failed"
    for (const source of req.sources) if (source === "workspaces") unavailable.push({ source, op: "session.snapshot", code })
  }
  const snap = snapshot ?? { workspaces: [], screens: [], panes: [], tabs: [], terminals: [], browsers: [] }
  const at = places(snap)
  const ctx: RankContext = { nowMs: req.nowMs, scope: req.scope, currentWorkspace: at.currentWorkspace, opened: req.opened }
  const inScope = (h: Hit) => req.scope === "all" || h.workspaceId === at.currentWorkspace || h.source === "files"
  const local = searchSnapshot(snap, matcher, req.sources, at).filter(inScope)

  const input: SourceInput = { call, matcher, scope: req.scope, at, terminals: snap.terminals, limit: req.limit, searchId: req.searchId }
  const jobs: Array<[SourceId, () => Promise<SourceResult>]> = []
  if (req.sources.includes("terminals")) jobs.push(["terminals", () => terminalText({ ...input, searchId: `${req.searchId}:terminals` })])
  if (req.sources.includes("browser")) jobs.push(["browser", () => history({ ...input, searchId: `${req.searchId}:history` })])
  if (req.sources.includes("apps")) jobs.push(["apps", () => apps({ ...input, searchId: `${req.searchId}:apps` }, req.selfId)])
  if (req.sources.includes("files")) jobs.push(["files", () => files({ ...input, searchId: `${req.searchId}:files` })])

  const done = new Map<SourceId, SourceResult>()
  const compose = (): SearchResponse => {
    const lists = [local, ...[...done.values()].map((r) => r.hits.filter(inScope))]
    const ranked = rank(lists, ctx)
    const truncatedSources = new Set([...done].filter(([, r]) => r.truncated).map(([s]) => s))
    const groups = group(ranked, groupLimit(req.density, req.sources.length), truncatedSources)
    const missing = [...unavailable, ...[...done.values()].flatMap((r) => (r.unavailable ? [r.unavailable] : []))]
    return {
      query: q.raw,
      scope: req.scope,
      groups,
      ranked,
      top: activeHit(ranked, null),
      unavailable: missing,
      truncated: groups.some((g) => g.truncated),
      pending: jobs.map(([s]) => s).filter((s) => !done.has(s)),
      currentWorkspace: at.currentWorkspace
    }
  }
  if (jobs.length) onPartial?.(compose())
  await Promise.all(
    jobs.map(async ([source, job]) => {
      try {
        done.set(source, await job())
      } catch (e) {
        done.set(source, { hits: [], truncated: false, unavailable: { source, op: "", code: String((e as { code?: unknown })?.code ?? "operation.failed") } })
      }
      if (done.size < jobs.length) onPartial?.(compose())
    })
  )
  return compose()
}
