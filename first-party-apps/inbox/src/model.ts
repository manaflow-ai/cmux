/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The inbox model: pure functions that turn cmux notifications, agents and
// GitHub work items into one ordered triage list. No cmux calls here.

import { isDone, isSeen, snoozedUntil, type Ledger } from "./ledger.ts"

export type Source = "agent" | "notification" | "github"
export type Kind = "agentBlocked" | "agentDone" | "agentIdle" | "notification" | "reviewRequested" | "checksFailing" | "mention"
export type Level = "info" | "warning" | "error"

export interface Item {
  /** Stable id: `agent:<agent id>`, `notification:<notification id>`, `github:<owner/repo>#<number>`. */
  id: string
  source: Source
  kind: Kind
  title: string
  /** Second line: terminal title, repository and number, or a notification subtitle. */
  detail: string
  /** Longer text for detail areas (notification body). */
  body?: string
  /** Last change in ms; done and seen stamps compare with it, so a changed item comes back. */
  at: number
  /** The source itself says the item is unread (cmux notification not yet read). */
  unreadHint: boolean
  /** The user's own work (agents, notifications, own pull requests) versus requests from others. */
  mine: boolean
  level?: Level
  terminal?: string
  /** cmux notification ids this item stands for (acknowledged when it is read or done). */
  notifications: string[]
  url?: string
  repo?: string
  number?: number
  author?: string
}

export interface ViewItem extends Item {
  unread: boolean
  snoozedUntil: number | null
  workspace: { id: string; name: string } | null
}

export interface Location {
  workspaceId: string
  workspaceName: string
  tabId: string | null
}

export interface BuildOptions {
  clientId: string
  includeIdle: boolean
  includeDone: boolean
  maxAgeDays: number
  now: number
}

const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v.trim() : null)
const capitalized = (s: string) => s.charAt(0).toUpperCase() + s.slice(1)
const firstLine = (s: string | undefined) => (s ?? "").split("\n").map((l) => l.trim()).find(Boolean) ?? ""

/** The name shown for an agent: its own name when the producer gave one, else the agent kind ("Claude"). */
export function agentName(a: Cmux.AgentSnapshot, fallback: string): string {
  const extra = (a.extra ?? {}) as Record<string, unknown>
  const name = str(extra.name) ?? str(extra.title) ?? str(a.source_session)
  return name ? capitalized(name) : fallback
}

const AGENT_KIND: Partial<Record<Cmux.AgentState, Kind>> = { blocked: "agentBlocked", done: "agentDone", idle: "agentIdle" }

/** Agents that need the user (blocked, done, and idle when asked), with their terminal's notifications folded in. */
export function agentItems(
  agents: readonly Cmux.AgentSnapshot[],
  notifications: readonly Cmux.NotificationSnapshot[],
  terminals: ReadonlyMap<string, Cmux.TerminalSnapshot>,
  options: Pick<BuildOptions, "clientId" | "includeIdle" | "includeDone">,
  fallbackName: string
): Item[] {
  const items: Item[] = []
  for (const a of agents) {
    const kind = AGENT_KIND[a.state]
    if (!kind || (kind === "agentIdle" && !options.includeIdle) || (kind === "agentDone" && !options.includeDone)) continue
    const related = notifications.filter((n) => n.terminal_id === a.terminal_id).sort((x, y) => Number(y.created_at_ms) - Number(x.created_at_ms))
    const latest = related[0]
    const terminal = terminals.get(a.terminal_id)
    const terminalLabel = str(terminal?.title) ?? str(terminal?.cwd) ?? ""
    items.push({
      id: `agent:${a.id}`,
      source: "agent",
      kind,
      title: agentName(a, fallbackName),
      detail: latest ? str(latest.subtitle) ?? (firstLine(latest.body) || latest.title) : terminalLabel,
      body: latest ? [latest.title, latest.body].filter(Boolean).join("\n") : undefined,
      at: Math.max(Number(a.updated_at_ms) || 0, ...related.map((n) => Number(n.created_at_ms) || 0)),
      unreadHint: true,
      mine: true,
      terminal: a.terminal_id,
      notifications: related.map((n) => n.id)
    })
  }
  return items
}

/** cmux notifications that no agent item already stands for. */
export function notificationItems(notifications: readonly Cmux.NotificationSnapshot[], claimed: ReadonlySet<string>, clientId: string): Item[] {
  return notifications
    .filter((n) => !claimed.has(n.id))
    .map((n) => ({
      id: `notification:${n.id}`,
      source: "notification" as const,
      kind: "notification" as const,
      title: n.title,
      detail: str(n.subtitle) ?? firstLine(n.body),
      body: n.body || undefined,
      at: Number(n.created_at_ms) || 0,
      unreadHint: n.unread && !n.read_by.includes(clientId),
      mine: true,
      level: n.level,
      terminal: n.terminal_id,
      notifications: [n.id]
    }))
}

/** Lower is more urgent. */
export function priority(item: Pick<Item, "kind" | "level">): number {
  switch (item.kind) {
    case "agentBlocked":
      return 0
    case "checksFailing":
      return 1
    case "notification":
      return item.level === "error" ? 1 : item.level === "warning" ? 3 : 4
    case "reviewRequested":
      return 2
    case "agentDone":
      return 3
    case "mention":
      return 4
    case "agentIdle":
      return 5
  }
}

/** Most urgent first, then newest. */
export const compareItems = (a: Item, b: Item) => priority(a) - priority(b) || b.at - a.at || a.id.localeCompare(b.id)

export interface Sources {
  agents: readonly Cmux.AgentSnapshot[]
  notifications: readonly Cmux.NotificationSnapshot[]
  terminals: ReadonlyMap<string, Cmux.TerminalSnapshot>
  github: readonly Item[]
  locations: ReadonlyMap<string, Location>
}

/** Every item with its triage state applied (done items are dropped; snoozed ones are marked). */
export function buildItems(sources: Sources, ledger: Ledger, options: BuildOptions, fallbackName: string): ViewItem[] {
  const agents = agentItems(sources.agents, sources.notifications, sources.terminals, options, fallbackName)
  const claimed = new Set(agents.flatMap((a) => a.notifications))
  const oldest = options.now - options.maxAgeDays * 86_400_000
  const all = [...agents, ...notificationItems(sources.notifications, claimed, options.clientId), ...sources.github]
  const out: ViewItem[] = []
  for (const item of all) {
    if (item.source !== "agent" && options.maxAgeDays > 0 && item.at < oldest) continue
    if (isDone(ledger, item.id, item.at)) continue
    const location = item.terminal ? sources.locations.get(item.terminal) : undefined
    out.push({
      ...item,
      unread: item.unreadHint && !isSeen(ledger, item.id, item.at),
      snoozedUntil: snoozedUntil(ledger, item.id, options.now),
      workspace: location ? { id: location.workspaceId, name: location.workspaceName } : null
    })
  }
  return out.sort(compareItems)
}

export interface Filters {
  source: "all" | Source
  unreadOnly: boolean
  mineOnly: boolean
  showSnoozed: boolean
}

export const DEFAULT_FILTERS: Filters = { source: "all", unreadOnly: false, mineOnly: false, showSnoozed: false }

/** Applies the user's filters. Snoozed items show only in the snoozed view. */
export function filterItems(items: readonly ViewItem[], f: Filters): ViewItem[] {
  return items.filter(
    (i) =>
      (f.showSnoozed ? i.snoozedUntil !== null : i.snoozedUntil === null) &&
      (f.source === "all" || i.source === f.source) &&
      (!f.unreadOnly || i.unread) &&
      (!f.mineOnly || i.mine)
  )
}

export interface Group {
  key: string
  /** Display label when the key is not a localizable source. */
  label: string
  source: Source | null
  items: ViewItem[]
}

const SOURCE_ORDER: Source[] = ["agent", "notification", "github"]

/** Groups by source (fixed order) or by workspace (GitHub items by repository, terminal-less items under `other`). */
export function groupItems(items: readonly ViewItem[], by: "source" | "workspace", otherLabel: string): Group[] {
  if (by === "source") {
    return SOURCE_ORDER.map((source) => ({ key: source, label: source, source, items: items.filter((i) => i.source === source) })).filter((g) => g.items.length > 0)
  }
  const groups = new Map<string, Group>()
  for (const item of items) {
    const key = item.workspace ? `workspace:${item.workspace.id}` : item.repo ? `repo:${item.repo}` : "other"
    const label = item.workspace?.name ?? item.repo ?? otherLabel
    let g = groups.get(key)
    if (!g) groups.set(key, (g = { key, label, source: null, items: [] }))
    g.items.push(item)
  }
  // Groups follow their most urgent item; "other" goes last.
  return [...groups.values()].sort((a, b) => (a.key === "other" ? 1 : b.key === "other" ? -1 : compareItems(a.items[0]!, b.items[0]!)))
}

export interface Counts {
  /** Unread items that are not snoozed or done (the badge). */
  unread: number
  /** Agents waiting for input (the badge turns to warning). */
  blocked: number
  /** Items not snoozed or done. */
  open: number
  snoozed: number
}

export function countItems(items: readonly ViewItem[]): Counts {
  let unread = 0
  let blocked = 0
  let open = 0
  let snoozed = 0
  for (const i of items) {
    if (i.snoozedUntil !== null) {
      snoozed++
      continue
    }
    open++
    if (i.unread) unread++
    if (i.kind === "agentBlocked") blocked++
  }
  return { unread, blocked, open, snoozed }
}

/** Maps each terminal to its workspace through tab -> pane -> screen -> workspace. */
export function locateTerminals(layout: {
  workspaces: readonly Cmux.WorkspaceSnapshot[]
  screens: readonly Cmux.ScreenSnapshot[]
  panes: readonly Cmux.PaneSnapshot[]
  tabs: readonly Cmux.TabSnapshot[]
  terminals: readonly Cmux.TerminalSnapshot[]
}): Map<string, Location> {
  const workspaces = new Map(layout.workspaces.map((w) => [w.id, w]))
  const screens = new Map(layout.screens.map((s) => [s.id, s]))
  const panes = new Map(layout.panes.map((p) => [p.id, p]))
  const tabs = new Map(layout.tabs.map((t) => [t.id, t]))
  const out = new Map<string, Location>()
  for (const terminal of layout.terminals) {
    const tab = terminal.tab_id ? tabs.get(terminal.tab_id) : undefined
    const screen = tab ? screens.get(panes.get(tab.pane_id)?.screen_id ?? "") : undefined
    const workspace = screen ? workspaces.get(screen.workspace_id) : undefined
    if (workspace) out.set(terminal.id, { workspaceId: workspace.id, workspaceName: workspace.name, tabId: tab?.id ?? null })
  }
  return out
}

/** The item after `id` in `order` (wrapping), or the first item. */
export function neighbor(order: readonly { id: string }[], id: string | null, step: 1 | -1): string | null {
  if (order.length === 0) return null
  const index = id ? order.findIndex((i) => i.id === id) : -1
  if (index < 0) return order[step === 1 ? 0 : order.length - 1]!.id
  return order[(index + step + order.length) % order.length]!.id
}

/** JSON shape of an item for agents (the `list` command / MCP tool). */
export function itemJSON(i: ViewItem) {
  return {
    id: i.id,
    source: i.source,
    kind: i.kind,
    title: i.title,
    detail: i.detail,
    unread: i.unread,
    updated_at: new Date(i.at).toISOString(),
    snoozed_until: i.snoozedUntil === null ? null : new Date(i.snoozedUntil).toISOString(),
    workspace: i.workspace?.name ?? null,
    terminal_id: i.terminal ?? null,
    url: i.url ?? null,
    repo: i.repo ?? null,
    number: i.number ?? null,
    level: i.level ?? null
  }
}
