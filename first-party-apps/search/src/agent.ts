// The JSON the `search` command returns to the palette, the CLI and MCP
// clients. Stable field names, plain strings, every result's open op included,
// and every source that was not searched named with its reason. Pure.

import type { SearchResponse } from "./engine.ts"
import { joinSegments } from "./match.ts"
import type { Target } from "./model.ts"

export interface AgentHit {
  id: string
  source: string
  kind: string
  title: string
  location: string
  /** The matched line (terminal, file, app item) with the match in `match`. */
  preview: string | null
  match: string | null
  score: number
  updated_at_ms: number | null
  workspace: string | null
  /** The op (and params) that opens this result; callable by the agent with its own grant. */
  open: Target
}

export interface AgentResult {
  query: string
  scope: "workspace" | "all"
  results: AgentHit[]
  /** More matches exist than were returned. */
  truncated: boolean
  /** Sources that were not searched and why (`operation.unsupported`, `scope.missing`, ...). */
  unavailable: Array<{ source: string; op: string; code: string }>
}

export function toAgentResult(r: SearchResponse, limit: number): AgentResult {
  return {
    query: r.query,
    scope: r.scope,
    results: r.ranked.slice(0, limit).map((h) => ({
      id: h.id,
      source: h.source,
      kind: h.kind,
      title: h.title,
      location: h.location,
      preview: h.preview ? joinSegments(h.preview) : null,
      match: h.preview ? h.preview.match : h.titleRange ? h.title.slice(h.titleRange.start, h.titleRange.start + h.titleRange.length) : null,
      score: h.score,
      updated_at_ms: h.updatedAtMs,
      workspace: h.workspaceId,
      open: h.target
    })),
    truncated: r.truncated || r.ranked.length > limit,
    unavailable: r.unavailable.map((u) => ({ source: u.source, op: u.op, code: u.code }))
  }
}
