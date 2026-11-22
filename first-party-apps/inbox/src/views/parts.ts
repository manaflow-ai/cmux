/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// View pieces shared by the variants: rows, menus, filter controls, notices,
// empty and error states. Everything renders feed items as the owner sent them.

import { answer, decline, markAllDone, markAllRead, markDone, markRead, openItem, snoozeItems, unarchive } from "../actions.ts"
import { answerButtons, approveAnswer, formOf } from "../answers.ts"
import { isOpenRequest, type FeedItem, type PosterKind } from "../feed.ts"
import { t } from "../l10n.ts"
import { counts, filters, groupBy, notice, setFilters, setGrouping, SOURCES, type FeedView, type SourceFilter } from "../store.ts"
import { ago, clock, snoozePresets } from "../time.ts"

const BUILT_IN_KINDS = new Set(["question", "choice", "approve", "confirm", "sign-in", "passkey", "review", "input", "file", "handoff"])

/** "Choose", "Approval", ...; notices have no kind label, custom kinds read "Request". */
export function kindLabel(i: FeedItem): string {
  if (i.type !== "request") return ""
  return BUILT_IN_KINDS.has(i.kind) ? t(`kind.${i.kind}`) : t("kind.custom")
}

export const sourceLabel = (k: SourceFilter | PosterKind) => t(`source.${k}`)

const KIND_SYMBOLS: Record<string, string> = {
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

const POSTER_SYMBOLS: Record<string, string> = { agent: "sparkles", harness: "sparkles", app: "app", server: "server.rack", vm: "cloud", automation: "play.circle", integration: "link", system: "gearshape", user: "person" }

export function itemSymbol(i: FeedItem): string {
  if (i.type === "request") return KIND_SYMBOLS[i.kind] ?? "questionmark.bubble"
  if (i.priority === "urgent" || i.priority === "high") return "exclamationmark.triangle"
  return POSTER_SYMBOLS[i.poster.kind] ?? "bell"
}

export function itemTint(i: FeedItem): string {
  if (i.priority === "urgent") return "danger"
  if (isOpenRequest(i) || i.priority === "high") return "warning"
  return i.priority === "low" ? "tertiary" : "secondary"
}

/** Workspace names for context ids (live; empty without `workspace:read`). */
export function workspaceNames(): (id: string | undefined) => string {
  const live = cmux.live<Cmux.WorkspaceSnapshot[]>("workspace.list", {})
  const byId = computed(() => new Map((live() ?? []).map((w) => [w.id, w.name])))
  return (id) => (id ? (byId().get(id) ?? "") : "")
}

/** "Approval · 2m · Claude · api-server"; snoozed and closed items say so. */
export function subtitleOf(i: FeedItem, now: number, workspace: (id: string | undefined) => string): string {
  let when = ago(i.updated_at, now)
  if (i.snoozed_until && i.snoozed_until > now) when = t("snooze.until", { time: clock(i.snoozed_until, now) })
  else if (i.state === "answered") when = t("state.answered", { time: ago(i.closed_at ?? i.updated_at, now) })
  else if (i.state === "cancelled") when = i.cancel?.reason === "declined" ? t("state.declined") : t("state.cancelled")
  else if (i.state === "expired") when = t("state.expired")
  return [kindLabel(i), when, i.poster.label, workspace(i.context.workspace)].filter(Boolean).join(" · ")
}

export function snoozeMenu(list: () => FeedItem[]): CmuxView {
  return Menu(
    t("action.snooze"),
    snoozePresets(Date.now()).map((p) => Button(p.label, () => snoozeItems(list(), p.until)))
  )
}

/** One-tap answers for the row menu: poster buttons with a value, and the kinds whose answer needs no typing. */
function answerMenu(i: FeedItem): CmuxView | null {
  if (!isOpenRequest(i)) return null
  const form = formOf(i)
  const entries: CmuxView[] = answerButtons(i).map((a) => Button(a.label, () => answer(i, a.answer)))
  if (form.kind === "approve") {
    entries.push(Button(t("answer.allow"), () => answer(i, approveAnswer("allow"))))
    if (form.scopes.includes("session")) entries.push(Button(t("answer.allowSession"), () => answer(i, approveAnswer("allow", "session"))))
    entries.push(Button(t("answer.deny"), () => answer(i, approveAnswer("deny"))))
  } else if (form.kind === "confirm") {
    entries.push(Button(form.confirmLabel ?? t("answer.confirm"), () => answer(i, { confirmed: true })))
    entries.push(Button(form.cancelLabel ?? t("answer.reject"), () => answer(i, { confirmed: false })))
  } else if (form.kind === "choice" && form.oneTap) {
    const q = form.questions[0]!
    for (const o of q.options) entries.push(Button(o.label, () => answer(i, { answers: { [q.id]: { selected: [o.id] } } })))
  }
  return entries.length ? Menu(t("action.answer"), entries) : null
}

/**
 * The per-item actions (row menu). An open request offers Open, its answers
 * and Decline; Done and Snooze appear only for items that may be archived or
 * snoozed (the owner refuses both for open requests).
 */
export function itemMenu(i: FeedItem): CmuxView[] {
  const views: CmuxView[] = [Button(i.kind === "sign-in" || i.kind === "passkey" ? t("answer.continueInBrowser") : t("action.open"), () => openItem(i))]
  if (isOpenRequest(i)) {
    const answers = answerMenu(i)
    if (answers) views.push(answers)
    views.push(Button(t("action.decline"), () => decline(i)).destructive())
  } else if (i.archived_at !== null) {
    views.push(Button(t("action.unarchive"), () => unarchive([i])))
  } else {
    views.push(Button(t("action.done"), () => markDone([i])))
    views.push(snoozeMenu(() => [i]))
  }
  if (i.read_at === null) views.push(Button(t("action.markRead"), () => markRead([i])))
  return views
}

/** A standard row; `tapOpens` opens on click, otherwise a click selects (and reads). */
export function ItemRow(item: () => FeedItem, workspace: (id: string | undefined) => string, options: { tapOpens: boolean; selectedId?: () => string | null; onSelect?: (i: FeedItem) => void }): CmuxView {
  return Row({
    title: () => item().title,
    subtitle: () => subtitleOf(item(), Date.now(), workspace),
    symbol: () => itemSymbol(item()),
    tint: () => itemTint(item()),
    unread: () => item().read_at === null,
    badge: () => (item().count > 1 ? item().count : null),
    selected: () => (options.selectedId ? options.selectedId() === item().id : false)
  })
    .help(() => [kindLabel(item()), item().title, item().body].filter(Boolean).join("\n"))
    .onTap(() => (options.tapOpens || !options.onSelect ? openItem(item()) : options.onSelect(item())))
    .contextMenu(() => itemMenu(item()))
}

/** "All", "Agents · Unread", ... */
export function filterSummary(): string {
  const f = filters()
  const parts = [f.showDone ? t("done.title") : sourceLabel(f.source)]
  if (f.needsResponseOnly && !f.showDone) parts.push(t("filter.needsResponseShort"))
  if (f.unreadOnly) parts.push(t("filter.unreadShort"))
  return parts.join(" · ")
}

/** The filter pull-down. The current choice shows disabled: menus have no checked state yet. */
export function FilterMenu(): CmuxView {
  return Menu(filterSummary, []).contextMenu(() => filterChoices())
}

function filterChoices(): CmuxView[] {
  const f = filters()
  const g = groupBy()
  return [
    ...SOURCES.map((s) => Button(sourceLabel(s), () => setFilters({ source: s })).disabled(f.source === s)),
    Divider(),
    Button(f.needsResponseOnly ? t("filter.everything") : t("filter.needsResponse"), () => setFilters({ needsResponseOnly: !f.needsResponseOnly })).disabled(f.showDone),
    Button(f.unreadOnly ? t("filter.showRead") : t("filter.unreadOnly"), () => setFilters({ unreadOnly: !f.unreadOnly })),
    Button(f.showDone ? t("done.hide") : t("done.show"), () => setFilters({ showDone: !f.showDone })),
    Divider(),
    Button(t("group.poster"), () => setGrouping("poster")).disabled(g === "poster"),
    Button(t("group.workspace"), () => setGrouping("workspace")).disabled(g === "workspace"),
    Button(t("group.thread"), () => setGrouping("thread")).disabled(g === "thread"),
    Divider(),
    Button(t("action.markAllRead"), () => markAllRead()),
    Button(t("action.markAllDone"), () => markAllDone()).disabled(f.showDone)
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
export function Empty(view: FeedView): CmuxView {
  return Group([
    () => {
      const err = view.error()
      if (err && view.items().length === 0) {
        if (err.code === "operation.unsupported") return EmptyState({ title: t("feed.unavailable"), message: t("feed.unavailableHelp"), symbol: "tray" })
        if (err.code === "scope.missing") return EmptyState({ title: t("feed.notGranted"), message: t("feed.notGrantedHelp"), symbol: "lock" })
        return EmptyState({ title: t("feed.error"), message: err.message, symbol: "exclamationmark.triangle" })
      }
      if (view.items().length > 0) return null
      if (!view.loaded()) return Text(t("loading")).font("caption").color("tertiary").paddingHorizontal(14).paddingVertical(6)
      const f = filters()
      if (f.showDone) return EmptyState({ title: t("done.empty"), symbol: "checkmark.circle" })
      if (f.source !== "all" || f.unreadOnly || f.needsResponseOnly) return EmptyState({ title: t("empty.filtered"), symbol: "line.3.horizontal.decrease.circle" })
      return EmptyState({ title: t("empty.title"), message: t("empty.message"), symbol: "checkmark.circle" })
    }
  ])
}

/** "Show Done" / "Back to Inbox" at the foot of the list. */
export function DoneFooter(): CmuxView {
  return Group([
    () => {
      const showing = filters().showDone
      return HStack([Icon(showing ? "chevron.left" : "archivebox").font("caption").color("tertiary"), Text(showing ? t("done.hide") : t("done.show")).font("caption").color("secondary"), Spacer()])
        .paddingHorizontal(14)
        .paddingVertical(4)
        .cursor("pointer")
        .onTap(() => setFilters({ showDone: !showing }))
    }
  ])
}

/**
 * The badge: open requests in the warning tone while any wait, else unread
 * items. The owner's counts have no "unread notices" figure (README, gaps).
 */
export const badgeOf = (c: { open_requests: number; unread: number } | null) =>
  !c ? null : c.open_requests > 0 ? { n: c.open_requests, tone: "warning" } : c.unread > 0 ? { n: c.unread, tone: "secondary" } : null

export function CountBadge(): CmuxView {
  const badge = computed(() => badgeOf(counts()))
  const shown = computed(() => badge() !== null)
  return Group([() => (shown() ? Badge(() => badge()?.n ?? 0, () => badge()?.tone ?? "secondary") : null)])
}
