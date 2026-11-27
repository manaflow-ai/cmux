/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Names from one session snapshot: workspaces, terminal tabs (title, cwd) and
// browser tabs (title, url). Pure: the engine reads the snapshot once.

import type { Matcher, NameMatch } from "../match.ts"
import type { Hit } from "../model.ts"
import type { SourceId } from "../query.ts"

type Snapshot = Pick<Cmux.ResourceSnapshot, "workspaces" | "screens" | "panes" | "tabs" | "terminals" | "browsers">

/** Lookups from any tab/terminal/browser to its workspace. */
export interface Places {
  workspaceOfTab(tabId: string | null | undefined): string | null
  workspaceName(workspaceId: string | null): string
  currentWorkspace: string | null
  /** Working directories of terminals, optionally only in one workspace. */
  folders(workspaceId: string | null): string[]
}

export function places(snapshot: Snapshot): Places {
  const wsOfScreen = new Map(snapshot.screens.map((s) => [s.id, s.workspace_id]))
  const wsOfPane = new Map(snapshot.panes.map((p) => [p.id, wsOfScreen.get(p.screen_id) ?? null]))
  const wsOfTab = new Map(snapshot.tabs.map((t) => [t.id, wsOfPane.get(t.pane_id) ?? null]))
  const names = new Map(snapshot.workspaces.map((w) => [w.id, w.name]))
  const workspaceOfTab = (tabId: string | null | undefined) => (tabId ? (wsOfTab.get(tabId) ?? null) : null)
  return {
    workspaceOfTab,
    workspaceName: (id) => (id ? (names.get(id) ?? "") : ""),
    currentWorkspace: snapshot.workspaces.find((w) => w.focused)?.id ?? null,
    folders(workspaceId) {
      const out: string[] = []
      for (const t of snapshot.terminals) {
        if (!t.cwd) continue
        if (workspaceId && workspaceOfTab(t.tab_id) !== workspaceId) continue
        out.push(t.cwd)
      }
      return distinctRoots(out)
    }
  }
}

/** Drops duplicates and folders inside another listed folder; keeps at most `max`. */
export function distinctRoots(paths: readonly string[], max = 8): string[] {
  const clean = [...new Set(paths.map((p) => (p.length > 1 ? p.replace(/\/+$/, "") : p)))].sort((a, b) => a.length - b.length)
  const out: string[] = []
  for (const p of clean) {
    if (out.some((root) => root === "/" || p === root || p.startsWith(`${root}/`))) continue
    out.push(p)
    if (out.length >= max) break
  }
  return out
}

/** The better of a primary-field match and a secondary-field match (weighted 0.7). */
function best(primary: NameMatch | null, secondary: NameMatch | null): { quality: number; primary: boolean; match: NameMatch } | null {
  const a = primary ? primary.quality : -1
  const b = secondary ? Math.round(secondary.quality * 0.7) : -1
  if (a < 0 && b < 0) return null
  return a >= b ? { quality: a, primary: true, match: primary! } : { quality: b, primary: false, match: secondary! }
}

const lastPathPart = (p: string) => p.replace(/\/+$/, "").split("/").pop() || p
const home = (p: string) => p.replace(/^\/Users\/[^/]+/, "~").replace(/^\/home\/[^/]+/, "~")

export function searchSnapshot(snapshot: Snapshot, matcher: Matcher, sources: readonly SourceId[], at: Places): Hit[] {
  const hits: Hit[] = []
  const base = { preview: null, updatedAtMs: null, score: 0 }
  if (sources.includes("workspaces")) {
    for (const w of snapshot.workspaces) {
      const m = matcher.name(w.name)
      if (!m) continue
      hits.push({ ...base, id: `workspace:${w.id}`, source: "workspaces", kind: "workspace", title: w.name, location: "", symbol: "square.stack", titleRange: m.range, quality: m.quality, workspaceId: w.id, target: { op: "workspace.focus", params: { workspace: w.id } } })
    }
  }
  const tabName = new Map(snapshot.tabs.map((t) => [t.id, t.name]))
  if (sources.includes("terminals")) {
    for (const term of snapshot.terminals) {
      if (!term.tab_id) continue
      const title = tabName.get(term.tab_id) || term.title || (term.cwd ? lastPathPart(term.cwd) : "")
      const m = best(matcher.name(title), term.cwd ? matcher.name(term.cwd) : null)
      if (!m) continue
      const ws = at.workspaceOfTab(term.tab_id)
      const where = [at.workspaceName(ws), term.cwd ? home(term.cwd) : ""].filter(Boolean).join(" · ")
      hits.push({ ...base, id: `terminal:${term.id}`, source: "terminals", kind: "terminal", title, location: where, symbol: term.running ? "terminal" : "terminal.fill", titleRange: m.primary ? m.match.range : null, quality: m.quality, workspaceId: ws, target: { op: "tab.focus", params: ws ? { tab: term.tab_id, workspace: ws } : { tab: term.tab_id } } })
    }
  }
  if (sources.includes("browser")) {
    for (const b of snapshot.browsers) {
      const title = tabName.get(b.tab_id) || b.title || b.url
      const m = best(matcher.name(title), matcher.name(b.url))
      if (!m) continue
      const ws = at.workspaceOfTab(b.tab_id)
      const where = [at.workspaceName(ws), hostOf(b.url)].filter(Boolean).join(" · ")
      hits.push({ ...base, id: `browser:${b.id}`, source: "browser", kind: "browserTab", title, location: where, symbol: "globe", titleRange: m.primary ? m.match.range : null, quality: m.quality, workspaceId: ws, target: { op: "tab.focus", params: ws ? { tab: b.tab_id, workspace: ws } : { tab: b.tab_id } } })
    }
  }
  return hits
}

export function hostOf(url: string): string {
  const m = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i.exec(url)
  return m ? m[1]!.replace(/^www\./, "") : url
}
