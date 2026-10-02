/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View pieces shared by the variants: rows, menus, filter controls, notices,
// empty and error states. Everything renders feed items as the owner sent them.

import { markAllSeen, markDone, markSeen, openItem, reopen, respond, snoozeItems } from "../actions.ts"
import type { FeedItem, RequestKind, SourceKind } from "../feed.ts"
import { t } from "../l10n.ts"
import { counts, feedError, filters, groupBy, items, loaded, notice, setFilters, setGrouping, type SourceFilter } from "../store.ts"
import { ago, clock, snoozePresets } from "../time.ts"

const REQUEST_LABELS: Record<RequestKind, [string, string]> = {
  question: ["request.question", "Question"],
  choice: ["request.choice", "Choose"],
  approve: ["request.approve", "Approval"],
  confirm: ["request.confirm", "Confirm"],
  "sign-in": ["request.sign-in", "Sign-in"],
  passkey: ["request.passkey", "Passkey"],
  review: ["request.review", "Review"],
  input: ["request.input", "Input"],
  file: ["request.file", "File"],
  handoff: ["request.handoff", "Handoff"]
}

const SOURCE_LABELS: Record<SourceKind, [string, string]> = {
  agent: ["source.agent", "Agents"],
  app: ["source.app", "Apps"],
  run: ["source.run", "Runs"],
  integration: ["source.integration", "Integrations"],
  user: ["source.user", "People"]
}

const FILTER_LABELS: Record<SourceFilter, [string, string]> = {
  all: ["filter.all", "All"],
  agent: ["source.agent", "Agents"],
  integration: ["source.integration", "Integrations"],
  other: ["filter.other", "Apps and Runs"]
}

export const sourceKindLabel = (k: SourceKind) => t(...SOURCE_LABELS[k])
export const filterLabel = (f: SourceFilter) => t(...FILTER_LABELS[f])

/** "Choose", "Approval", ...; notifications and watches have no kind label. */
export function kindLabel(i: FeedItem): string {
  if (i.kind === "request" && i.requestKind) return t(...REQUEST_LABELS[i.requestKind])
  if (i.kind === "watch") return t("kind.watch", "In progress")
  return ""
}

const REQUEST_SYMBOLS: Record<RequestKind, string> = {
  question: "questionmark.bubble",
  choice: "list.bullet",
  approve: "checkmark.shield",
  confirm: "exclamationmark.bubble",
  "sign-in": "person.badge.key",
  passkey: "key",
  review: "eye",
  input: "text.cursor",
  file: "doc",
  handoff: "arrow.triangle.branch"
}

const SOURCE_SYMBOLS: Record<SourceKind, string> = { agent: "sparkles", app: "app", run: "play.circle", integration: "link", user: "person" }

export function itemSymbol(i: FeedItem): string {
  if (i.kind === "request" && i.requestKind) return REQUEST_SYMBOLS[i.requestKind]
  if (i.kind === "watch") return "hourglass"
  if (i.urgency === "critical" || i.urgency === "high") return "exclamationmark.triangle"
  return SOURCE_SYMBOLS[i.source.kind]
}

export function itemTint(i: FeedItem): string {
  if (i.urgency === "critical") return "danger"
  if (i.needsResponse || i.urgency === "high") return "warning"
  if (i.kind === "watch") return "accent"
  return i.urgency === "low" ? "tertiary" : "secondary"
}

/** "Choose · 2m · Claude · api-server"; snoozed items say when they come back. */
export function subtitleOf(i: FeedItem, now: number): string {
  const when = i.snoozedUntil ? t("snooze.until", "Snoozed until {time}", { time: clock(Date.parse(i.snoozedUntil), now) }) : ago(Date.parse(i.updatedAt), now)
  const place = i.subject.workspaceName ?? ""
  return [kindLabel(i), when, i.source.name, place].filter(Boolean).join(" · ")
}

export function snoozeMenu(list: () => FeedItem[]): CmuxView {
  return Menu(
    t("action.snooze", "Snooze"),
    snoozePresets(Date.now()).map((p) => Button(p.label, () => snoozeItems(list(), p.until)))
  )
}

/** Response choices as menu entries (so a request can be answered from the row menu). */
function respondMenu(i: FeedItem): CmuxView | null {
  const r = i.response
  if (!i.needsResponse || !r) return null
  const entries: CmuxView[] =
    r.type === "choice"
      ? r.options.map((o) => Button(o.label, () => respond(i, { choice: o.value })))
      : r.type === "approve"
        ? [Button(t("respond.approve", "Approve"), () => respond(i, { approved: true })), Button(t("respond.deny", "Deny"), () => respond(i, { approved: false }))]
        : r.type === "confirm"
          ? [Button(t("respond.confirm", "Confirm"), () => respond(i, { confirmed: true })), Button(t("respond.cancel", "Cancel"), () => respond(i, { confirmed: false }))]
          : []
  return entries.length ? Menu(t("action.respond", "Respond"), entries) : null
}

/** The per-item actions (row menu). */
export function itemMenu(i: FeedItem): CmuxView[] {
  const views: CmuxView[] = []
  if (i.open) views.push(Button(t("action.open", "Open"), () => openItem(i)))
  const answer = respondMenu(i)
  if (answer) views.push(answer)
  views.push(Button(t("action.done", "Mark as Done"), () => markDone([i])))
  views.push(i.snoozedUntil ? Button(t("action.unsnooze", "Unsnooze"), () => reopen([i])) : snoozeMenu(() => [i]))
  if (i.seenAt === null) views.push(Button(t("action.markSeen", "Mark as Seen"), () => markSeen([i])))
  return views
}

/** A standard row; `tapOpens` opens on click, otherwise a click selects. */
export function ItemRow(item: () => FeedItem, options: { tapOpens: boolean; selectedId?: () => string | null; onSelect?: (id: string) => void }): CmuxView {
  return Row({
    title: () => item().title,
    subtitle: () => subtitleOf(item(), Date.now()),
    symbol: () => itemSymbol(item()),
    tint: () => itemTint(item()),
    unread: () => item().seenAt === null,
    selected: () => (options.selectedId ? options.selectedId() === item().id : false)
  })
    .help(() => [kindLabel(item()), item().title, item().body ?? ""].filter(Boolean).join("\n"))
    .onTap(() => (options.tapOpens || !options.onSelect ? openItem(item()) : options.onSelect(item().id)))
    .contextMenu(() => itemMenu(item()))
}

/** "All", "Agents · Unseen", ... */
export function filterSummary(): string {
  const f = filters()
  const label = f.showSnoozed ? t("snoozed.title", "Snoozed") : filterLabel(f.source)
  const parts = [label]
  if (f.needsResponseOnly) parts.push(t("filter.needsResponseShort", "Needs you"))
  if (f.unseenOnly) parts.push(t("filter.unseenShort", "Unseen"))
  return parts.join(" · ")
}

/** The filter pull-down. The current source shows disabled: menus have no checked state yet. */
export function FilterMenu(): CmuxView {
  return Menu(filterSummary, []).contextMenu(() => filterChoices())
}

function filterChoices(): CmuxView[] {
  const f = filters()
  const sources: SourceFilter[] = ["all", "agent", "integration", "other"]
  const g = groupBy()
  return [
    ...sources.map((s) => Button(filterLabel(s), () => setFilters({ source: s, showSnoozed: false })).disabled(f.source === s && !f.showSnoozed)),
    Divider(),
    Button(f.needsResponseOnly ? t("filter.everything", "Show Everything") : t("filter.needsResponse", "Show Only What Needs a Response"), () => setFilters({ needsResponseOnly: !f.needsResponseOnly })),
    Button(f.unseenOnly ? t("filter.showSeen", "Show Seen Items") : t("filter.unseenOnly", "Show Unseen Only"), () => setFilters({ unseenOnly: !f.unseenOnly })),
    Button(f.showSnoozed ? t("snoozed.hide", "Hide Snoozed") : t("snoozed.show", "Show Snoozed"), () => setFilters({ showSnoozed: !f.showSnoozed })),
    Divider(),
    Button(t("group.source", "Group by Source"), () => setGrouping("source")).disabled(g === "source"),
    Button(t("group.workspace", "Group by Workspace"), () => setGrouping("workspace")).disabled(g === "workspace"),
    Button(t("group.thread", "Group by Thread"), () => setGrouping("thread")).disabled(g === "thread"),
    Divider(),
    Button(t("action.markAllSeen", "Mark All as Seen"), () => markAllSeen()),
    Button(t("action.markAllDone", "Mark All as Done"), () => markDone(items()))
  ]
}

/** Transient notices, one muted line. */
export function Notices(): CmuxView {
  return Group([
    () =>
      notice()
        ? HStack({ spacing: 6 }, [Icon("exclamationmark.triangle").color("secondary").font("caption"), Text(notice()!).font("caption").color("secondary").lineLimit(2)])
            .paddingHorizontal(14)
            .paddingVertical(2)
        : null
  ])
}

/** Feed missing, loading, all clear, or nothing matching the filters. */
export function Empty(): CmuxView {
  return Group([
    () => {
      const err = feedError()
      if (err && items().length === 0) {
        if (err.code === "operation.unsupported") return EmptyState({ title: t("feed.unavailable", "The feed is not available yet"), message: t("feed.unavailableHelp", "This version of cmux has no feed owner."), symbol: "tray" })
        if (err.code === "scope.missing") return EmptyState({ title: t("feed.notGranted", "Feed access not granted"), message: t("feed.notGrantedHelp", "Allow it in Settings > Apps > Inbox."), symbol: "lock" })
        return EmptyState({ title: t("feed.error", "Could not load the feed"), message: err.message, symbol: "exclamationmark.triangle" })
      }
      if (items().length > 0) return null
      if (!loaded()) return Text(t("loading", "Loading…")).font("caption").color("tertiary").paddingHorizontal(14).paddingVertical(6)
      const f = filters()
      if (f.source !== "all" || f.unseenOnly || f.needsResponseOnly || f.showSnoozed) return EmptyState({ title: t("empty.filtered", "Nothing matches these filters"), symbol: "line.3.horizontal.decrease.circle" })
      return EmptyState({ title: t("empty.title", "Nothing needs you"), message: t("empty.message", "Agents, apps and integrations are all clear."), symbol: "checkmark.circle" })
    }
  ])
}

/** "3 snoozed" toggles the snoozed view. */
export function SnoozedFooter(): CmuxView {
  return Group([
    () => {
      const n = counts()?.snoozed ?? 0
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

const hasUnseen = computed(() => (counts()?.unseen ?? 0) > 0)

/** The unseen count; warning tone while something needs a response. */
export function UnseenBadge(): CmuxView {
  return Group([() => (hasUnseen() ? Badge(() => counts()?.unseen ?? 0, () => ((counts()?.needsResponse ?? 0) > 0 ? "warning" : "secondary")) : null)])
}

export const markAll = () => markAllSeen()
