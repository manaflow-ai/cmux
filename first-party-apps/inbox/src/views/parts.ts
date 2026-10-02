/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View pieces shared by the variants: rows, menus, filter controls, notices,
// the GitHub status row, empty states and the item context loader.

import { markAllRead, markDone, markRead, openItem, snoozeItems, unsnoozeItems } from "../actions.ts"
import { loadChecks, type CheckSummary } from "../github.ts"
import { t } from "../l10n.ts"
import type { Kind, Source, ViewItem } from "../model.ts"
import {
  attachLayout,
  counts,
  filters,
  github,
  githubRequest,
  groupBy,
  items,
  loaded,
  notice,
  now,
  refreshGithub,
  setFilters,
  setGrouping,
  sourceErrors,
  visible
} from "../store.ts"
import { ago, clock, snoozePresets } from "../time.ts"

const KIND_LABELS: Record<Kind, [string, string]> = {
  agentBlocked: ["kind.agentBlocked", "Needs input"],
  agentDone: ["kind.agentDone", "Finished"],
  agentIdle: ["kind.agentIdle", "Idle"],
  notification: ["kind.notification", "Notification"],
  reviewRequested: ["kind.reviewRequested", "Review requested"],
  checksFailing: ["kind.checksFailing", "Checks failing"],
  mention: ["kind.mention", "Mentioned"]
}

export const kindLabel = (kind: Kind) => t(...KIND_LABELS[kind])

const SOURCE_LABELS: Record<"all" | Source, [string, string]> = {
  all: ["source.all", "All"],
  agent: ["source.agent", "Agents"],
  notification: ["source.notification", "Notifications"],
  github: ["source.github", "GitHub"]
}

export const sourceLabel = (s: "all" | Source) => t(...SOURCE_LABELS[s])

export const SOURCE_SYMBOLS: Record<"all" | Source, string> = { all: "tray", agent: "sparkles", notification: "bell", github: "arrow.triangle.pull" }

export function kindSymbol(i: Pick<ViewItem, "kind" | "level">): string {
  switch (i.kind) {
    case "agentBlocked":
      return "exclamationmark.bubble"
    case "agentDone":
      return "checkmark.circle"
    case "agentIdle":
      return "moon"
    case "reviewRequested":
      return "eye"
    case "checksFailing":
      return "xmark.circle"
    case "mention":
      return "at"
    case "notification":
      return i.level === "error" ? "xmark.octagon" : i.level === "warning" ? "exclamationmark.triangle" : "bell"
  }
}

export function kindTint(i: Pick<ViewItem, "kind" | "level">): string {
  switch (i.kind) {
    case "agentBlocked":
      return "warning"
    case "agentDone":
      return "success"
    case "checksFailing":
      return "danger"
    case "reviewRequested":
    case "mention":
      return "accent"
    case "notification":
      return i.level === "error" ? "danger" : i.level === "warning" ? "warning" : "secondary"
    case "agentIdle":
      return "secondary"
  }
}

/** "Needs input · 5m · api-server #88": the age stays visible when the row truncates; snoozed items say when they come back. */
export function subtitleOf(i: ViewItem, at: number): string {
  const when = i.snoozedUntil !== null ? t("snooze.until", "Snoozed until {time}", { time: clock(i.snoozedUntil, at) }) : ago(i.at, at)
  const parts = i.source === "notification" ? [when, i.detail] : [kindLabel(i.kind), when, i.detail]
  return parts.filter(Boolean).join(" · ")
}

export function snoozeMenu(list: () => ViewItem[]): CmuxView {
  return Menu(
    t("action.snooze", "Snooze"),
    snoozePresets(now()).map((p) => Button(p.label, () => snoozeItems(list(), p.until)))
  )
}

/** The per-item actions (context menu and pull-down). */
export function itemMenu(i: ViewItem): CmuxView[] {
  const views: CmuxView[] = [
    Button(t("action.open", "Open"), () => openItem(i)),
    Button(t("action.done", "Mark as Done"), () => markDone([i])),
    i.snoozedUntil !== null ? Button(t("action.unsnooze", "Unsnooze"), () => unsnoozeItems([i])) : snoozeMenu(() => [i])
  ]
  if (i.unread) views.push(Button(t("action.markRead", "Mark as Read"), () => markRead([i])))
  return views
}

/** A standard row; `tapOpens` opens on click, otherwise a click selects. */
export function ItemRow(item: () => ViewItem, options: { tapOpens: boolean; selectedId?: () => string | null; onSelect?: (id: string) => void }): CmuxView {
  return Row({
    title: () => item().title,
    subtitle: () => subtitleOf(item(), now()),
    symbol: () => kindSymbol(item()),
    tint: () => kindTint(item()),
    unread: () => item().unread,
    selected: () => (options.selectedId ? options.selectedId() === item().id : false)
  })
    .help(() => [kindLabel(item().kind), item().title, item().detail].filter(Boolean).join("\n"))
    .onTap(() => (options.tapOpens || !options.onSelect ? openItem(item()) : options.onSelect(item().id)))
    .contextMenu(() => itemMenu(item()))
}

/** "All", "Agents · Unread", ... */
export function filterSummary(): string {
  const f = filters()
  const label = f.showSnoozed ? t("snoozed.count", "{n} snoozed", { n: counts().snoozed }) : sourceLabel(f.source)
  return f.unreadOnly ? t("filter.unreadSuffix", "{label} · Unread", { label }) : label
}

/** The filter pull-down (grouped variant). The current source is shown disabled: menus have no checked state yet. */
export function FilterMenu(): CmuxView {
  return Menu(filterSummary, [])
    .contextMenu(() => filterChoices())
}

export function filterChoices(): CmuxView[] {
  const f = filters()
  const sources: Array<"all" | Source> = ["all", "agent", "notification", "github"]
  return [
    ...sources.map((s) => Button(sourceLabel(s), () => setFilters({ source: s, showSnoozed: false })).disabled(f.source === s && !f.showSnoozed)),
    Divider(),
    Button(f.unreadOnly ? t("filter.showAll", "Show Read Items") : t("filter.unreadOnly", "Show Unread Only"), () => setFilters({ unreadOnly: !f.unreadOnly })),
    Button(f.mineOnly ? t("filter.includeRequests", "Include Requests from Others") : t("filter.mineOnly", "Show Only My Work"), () => setFilters({ mineOnly: !f.mineOnly })),
    Divider(),
    groupBy() === "source"
      ? Button(t("filter.groupByWorkspace", "Group by Workspace"), () => setGrouping("workspace"))
      : Button(t("filter.groupBySource", "Group by Source"), () => setGrouping("source")),
    Divider(),
    Button(t("action.markAllRead", "Mark All as Read"), () => markAllRead()),
    Button(t("action.markAllDone", "Mark All as Done"), () => markDone(visible())),
    Button(t("action.refresh", "Refresh"), () => refreshGithub(true))
  ]
}

/** Loads workspace names only while grouping by workspace (the reads live and die with this subtree). */
export function LayoutProbe(): CmuxView {
  return ForEach({ items: () => (groupBy() === "workspace" ? ["layout"] : []), key: (k: string) => k }, () => {
    attachLayout()
    return Group([])
  })
}

/** Source errors and transient notices, one muted line each. */
export function Notices(): CmuxView {
  const line = (text: string, tone: string) =>
    HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").color(tone).font("caption"), Text(text).font("caption").color("secondary").lineLimit(2)]).paddingHorizontal(14).paddingVertical(2)
  return Group([
    () => (sourceErrors().notification ? line(t("error.notification", "Notifications unavailable: {reason}", { reason: sourceErrors().notification! }), "warning") : null),
    () => (sourceErrors().agent ? line(t("error.agent", "Agents unavailable: {reason}", { reason: sourceErrors().agent! }), "warning") : null),
    () => (notice() ? line(notice()!, "secondary") : null)
  ])
}

/** A row at the end that explains a GitHub state the user can act on. */
export function GithubStatusRow(): CmuxView {
  return Group([
    () => {
      const f = filters()
      if (f.showSnoozed || (f.source !== "all" && f.source !== "github")) return null
      const g = github()
      if (g.status === "notGranted")
        return Row({ title: t("github.notGranted", "Connect GitHub"), subtitle: t("github.notGrantedHelp", "Allow GitHub read access in Settings > Apps > Inbox"), symbol: "link", tint: "secondary" }).onTap(() => refreshGithub(true))
      if (g.status === "unavailable")
        return Row({ title: t("github.unavailable", "GitHub through cmux is not available yet"), subtitle: t("github.unavailableHelp", "This cmux has no integration gateway"), symbol: "icloud.slash", tint: "tertiary" })
      if (g.status === "error" || g.status === "partial")
        return Row({ title: t("github.error", "Could not load GitHub"), subtitle: g.errors[0] ?? "", symbol: "exclamationmark.triangle", tint: "warning" }).onTap(() => refreshGithub(true))
      return null
    }
  ])
}

/** Loading, all-caught-up, or nothing-matches. */
export function Empty(): CmuxView {
  return Group([
    () => {
      if (visible().length > 0) return null
      if (!loaded()) return Text(t("loading", "Loading…")).font("caption").color("tertiary").paddingHorizontal(14).paddingVertical(6)
      if (items().length > 0) return EmptyState({ title: t("empty.filtered", "Nothing matches these filters"), symbol: "line.3.horizontal.decrease.circle" })
      return EmptyState({ title: t("empty.title", "Nothing needs you"), message: t("empty.message", "Agents, notifications and GitHub are all clear."), symbol: "checkmark.circle" })
    }
  ])
}

/** "3 snoozed" toggles the snoozed view. */
export function SnoozedFooter(): CmuxView {
  return Group([
    () => {
      const n = counts().snoozed
      const showing = filters().showSnoozed
      if (n === 0 && !showing) return null
      const title = showing ? t("snoozed.hide", "Hide Snoozed") : t("snoozed.count", "{n} snoozed", { n })
      return HStack([Icon(showing ? "chevron.left" : "moon.zzz").font("caption").color("tertiary"), Text(title).font("caption").color("secondary"), Spacer()])
        .paddingHorizontal(14)
        .paddingVertical(4)
        .cursor("pointer")
        .onTap(() => setFilters({ showSnoozed: !showing }))
    }
  ])
}

// Item context: what the agent shows, the notification body, or the failing checks.

const contextCache = new Map<string, string>()
const CONTEXT_CACHE_LIMIT = 64

const screenTail = (text: string, lines: number) =>
  text
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .filter((l) => l.trim())
    .slice(-lines)
    .join("\n")

export function checkText(s: CheckSummary): string {
  if (s.state === "fail") return t("github.checks.fail", "{n} failed: {names}", { n: s.counts.fail, names: s.failed.slice(0, 4).join(", ") })
  if (s.state === "pending") return t("github.checks.pending", "Checks running")
  if (s.state === "pass") return t("github.checks.pass", "All checks passed")
  return t("github.checks.neutral", "No check results")
}

/** A signal with context text for the item; loads once per item change, cached. */
export function itemContext(item: () => ViewItem | null): () => string | null {
  const [text, setText] = signal<string | null>(null)
  let key = ""
  const remember = (k: string, value: string) => {
    if (contextCache.size >= CONTEXT_CACHE_LIMIT) contextCache.delete(contextCache.keys().next().value!)
    contextCache.set(k, value)
    if (key === k) setText(value)
  }
  effect(() => {
    const i = item()
    const k = i ? `${i.id}@${i.at}` : ""
    if (k === key) return
    key = k
    setText(contextCache.get(k) ?? i?.body ?? null)
    if (!i || contextCache.has(k)) return
    if (i.source === "agent" && i.terminal) {
      cmux.terminal.screen
        .read({ terminal: i.terminal })
        .then((r) => remember(k, screenTail(r.text, 8)))
        .catch(() => {})
    } else if (i.kind === "checksFailing" && i.repo && i.number) {
      loadChecks(githubRequest, i.repo, i.number)
        .then((s) => remember(k, checkText(s)))
        .catch(() => {})
    } else if (i.source === "github" && i.author) {
      setText(t("github.by", "Opened by {author}", { author: i.author }))
    }
  })
  return text
}

const hasUnread = computed(() => counts().unread > 0)

/** The unread count; warning tone while an agent waits for input. */
export function UnreadBadge(): CmuxView {
  return Group([() => (hasUnread() ? Badge(() => counts().unread, () => (counts().blocked > 0 ? "warning" : "secondary")) : null)])
}
