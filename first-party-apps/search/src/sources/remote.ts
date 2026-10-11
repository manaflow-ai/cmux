/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Sources answered by owners outside the app VM: terminal text, browser
// history, files and other apps. Each turns an owner's answer into hits, or a
// typed "unavailable" when the op is missing or not granted.

import { t } from "../l10n.ts"
import { snippet, type Matcher } from "../match.ts"
import type { Hit, Unavailable } from "../model.ts"
import type { Scope, SourceId } from "../query.ts"
import { hostOf, type Places } from "./local.ts"
import type { FsSearchResult, HistorySearchResult, ProvidersQueryResult, TerminalSearchResult } from "./proposed.ts"

export type Call = (op: string, params: unknown) => Promise<unknown>

export interface SourceResult {
  hits: Hit[]
  truncated: boolean
  unavailable: Unavailable | null
}

export interface SourceInput {
  call: Call
  matcher: Matcher
  scope: Scope
  at: Places
  terminals: ReadonlyArray<Pick<Cmux.TerminalSnapshot, "id" | "tab_id" | "title" | "running">>
  limit: number
  searchId: string
}

const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : "operation.failed")
const unavailable = (source: SourceId, op: string, e: unknown): SourceResult => ({ hits: [], truncated: false, unavailable: { source, op, code: codeOf(e) } })
const base = { titleRange: null, score: 0 } as const

/** Terminal text through `terminal.search`; without it, the visible screens through `terminal.screen.read`. */
export async function terminalText(input: SourceInput): Promise<SourceResult> {
  const { call, matcher, scope, at } = input
  const here = scope === "workspace" ? at.currentWorkspace : null
  const inScope = input.terminals.filter((t) => !here || at.workspaceOfTab(t.tab_id) === here)
  const q = matcher.query
  try {
    const r = (await call("terminal.search", {
      query: q.text,
      regex: q.regex,
      case_sensitive: q.caseSensitive,
      ...(here ? { terminals: inScope.map((t) => t.id) } : { include_closed: true }),
      limit: input.limit,
      per_terminal: 3,
      context_chars: 80,
      search_id: input.searchId
    })) as TerminalSearchResult
    const hits = r.matches.map((m): Hit => {
      const ws = at.workspaceOfTab(m.tab)
      return {
        ...base,
        id: `terminalText:${m.terminal}:${m.row}`,
        source: "terminals",
        kind: "terminalText",
        title: m.title,
        location: [at.workspaceName(ws), m.closed ? t("location.closed", "closed") : ""].filter(Boolean).join(" · "),
        symbol: m.closed ? "clock.arrow.circlepath" : "text.magnifyingglass",
        preview: snippet(m.line_text, { start: m.match_start, length: m.match_length }),
        quality: 50,
        updatedAtMs: m.last_output_at_ms,
        workspaceId: ws,
        target: m.tab ? { op: "tab.focus", params: ws ? { tab: m.tab, workspace: ws } : { tab: m.tab }, reveal: { terminal: m.terminal, row: m.row } } : { op: "action.run", params: { id: "history.reopen", args: { terminal: m.terminal } } }
      }
    })
    return { hits, truncated: r.truncated, unavailable: null }
  } catch (e) {
    if (codeOf(e) !== "operation.unsupported") return unavailable("terminals", "terminal.search", e)
    return screens(input, inScope)
  }
}

/** Fallback: search only what each running terminal shows now (bounded: 12 terminals, 3 lines each). */
async function screens(input: SourceInput, terminals: SourceInput["terminals"]): Promise<SourceResult> {
  const { call, matcher, at } = input
  const running = terminals.filter((t) => t.running && t.tab_id).slice(0, 12)
  const reads = await Promise.allSettled(running.map((t) => call("terminal.screen.read", { terminal: t.id }) as Promise<Cmux.TerminalScreenResult>))
  const hits: Hit[] = []
  let denied: unknown = null
  reads.forEach((r, i) => {
    const term = running[i]!
    if (r.status === "rejected") {
      denied ??= r.reason
      return
    }
    let found = 0
    r.value.text.split("\n").forEach((line, row) => {
      if (found >= 3) return
      const range = matcher.find(line)
      if (!range) return
      found++
      const ws = at.workspaceOfTab(term.tab_id)
      hits.push({ ...base, id: `terminalScreen:${term.id}:${row}`, source: "terminals", kind: "terminalText", title: term.title, location: at.workspaceName(ws), symbol: "text.magnifyingglass", preview: snippet(line, range), quality: 50, updatedAtMs: null, workspaceId: ws, screenOnly: true, target: { op: "tab.focus", params: ws ? { tab: term.tab_id!, workspace: ws } : { tab: term.tab_id! } } })
    })
  })
  if (denied && !hits.length && reads.every((r) => r.status === "rejected")) return unavailable("terminals", "terminal.screen.read", denied)
  return { hits, truncated: false, unavailable: { source: "terminals", op: "terminal.search", code: "operation.unsupported" } }
}

export async function history(input: SourceInput): Promise<SourceResult> {
  if (input.scope === "workspace") return { hits: [], truncated: false, unavailable: null }
  const q = input.matcher.query
  try {
    const r = (await input.call("browser.history.search", { query: q.text, regex: q.regex, limit: input.limit, search_id: input.searchId })) as HistorySearchResult
    const hits = r.entries.map((e): Hit => {
      const m = input.matcher.name(e.title) ?? input.matcher.name(e.url)
      return { ...base, id: `history:${e.url}`, source: "browser", kind: "history", title: e.title || e.url, location: hostOf(e.url), symbol: "clock", titleRange: m && input.matcher.name(e.title) ? m.range : null, preview: null, quality: Math.max(40, Math.round((m?.quality ?? 50) * 0.9)), updatedAtMs: e.last_visit_ms, workspaceId: null, target: { op: "action.run", params: { id: "openBrowser", args: { url: e.url } } } }
    })
    return { hits, truncated: r.truncated, unavailable: null }
  } catch (e) {
    return unavailable("browser", "browser.history.search", e)
  }
}

export async function files(input: SourceInput): Promise<SourceResult> {
  const roots = input.at.folders(input.scope === "workspace" ? input.at.currentWorkspace : null)
  if (!roots.length) return { hits: [], truncated: false, unavailable: { source: "files", op: "fs.search", code: "no.roots" } }
  const q = input.matcher.query
  try {
    const r = (await input.call("fs.search", { roots, query: q.text, mode: "both", regex: q.regex, case_sensitive: q.caseSensitive, limit: input.limit, search_id: input.searchId })) as FsSearchResult
    const hits = r.matches.map((m): Hit => {
      const name = m.relative.split("/").pop() || m.relative
      const isName = m.kind === "name"
      const nameRange = isName ? input.matcher.name(name) : null
      return {
        ...base,
        id: isName ? `file:${m.path}` : `fileContent:${m.path}:${m.line ?? 0}`,
        source: "files",
        kind: isName ? "file" : "fileContent",
        title: name,
        location: isName ? m.relative : `${m.relative}:${m.line ?? 1}`,
        symbol: isName ? "doc" : "doc.text.magnifyingglass",
        titleRange: nameRange?.range ?? null,
        preview: isName || m.line_text === undefined ? null : snippet(m.line_text, { start: m.match_start, length: m.match_length }),
        quality: isName ? (nameRange?.quality ?? 60) : 45,
        updatedAtMs: m.modified_ms,
        workspaceId: null,
        target: { op: "action.run", params: { id: "file.open", args: m.line ? { path: m.path, line: m.line, column: m.column ?? 1 } : { path: m.path } } }
      }
    })
    return { hits, truncated: r.truncated, unavailable: null }
  } catch (e) {
    return unavailable("files", "fs.search", e)
  }
}

export async function apps(input: SourceInput, selfId: string): Promise<SourceResult> {
  if (input.scope === "workspace") return { hits: [], truncated: false, unavailable: null }
  try {
    const r = (await input.call("search.providers.query", { query: input.matcher.query.raw.trim(), limit_per_provider: Math.min(input.limit, 8), search_id: input.searchId })) as ProvidersQueryResult
    const hits: Hit[] = []
    let truncated = false
    for (const p of r.providers) {
      const appId = p.provider.split("#")[0]!
      if (appId === selfId || p.error) continue
      truncated ||= p.truncated
      for (const item of p.items) {
        const m = input.matcher.name(item.title)
        hits.push({
          ...base,
          id: `app:${p.provider}:${item.id}`,
          source: "apps",
          kind: "appItem",
          title: item.title,
          location: [p.title, item.subtitle].filter(Boolean).join(" · "),
          symbol: item.symbol ?? "square.grid.2x2",
          titleRange: m?.range ?? null,
          preview: item.line_text !== undefined && item.match_start !== undefined ? snippet(item.line_text, { start: item.match_start, length: item.match_length ?? 0 }) : null,
          quality: m?.quality ?? 50,
          updatedAtMs: item.updated_at_ms ?? null,
          workspaceId: null,
          target: { op: "action.run", params: { id: `app.${appId}#${item.open.command}`, args: item.open.args ?? {} } }
        })
      }
    }
    return { hits, truncated, unavailable: null }
  } catch (e) {
    return unavailable("apps", "search.providers.query", e)
  }
}
