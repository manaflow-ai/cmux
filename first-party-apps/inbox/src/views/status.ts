/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The status item: a tray glyph with the owner's unseen count (warning tone
// while something needs a response). It reads `feed.counts` once and then the
// counts every `feed.changed` carries. A click opens the most urgent unseen
// item; the menu lists the most urgent items.

import { markAllSeen, openItem } from "../actions.ts"
import { feed, type FeedItem } from "../feed.ts"
import { t } from "../l10n.ts"
import { attachCounts, counts, noticeFor, describe } from "../store.ts"
import { kindLabel, UnseenBadge } from "./parts.ts"

const MENU_ITEMS = 8

const [menuItems, setMenuItems] = signal<FeedItem[]>([])

/** The top items, read when the counts change (no list subscription for a badge). */
function loadTop() {
  feed
    .list({ filter: { status: ["open"] }, limit: MENU_ITEMS })
    .then((r) => setMenuItems(r.items))
    .catch(() => setMenuItems([]))
}

export function StatusItem(): CmuxView {
  attachCounts()
  effect(() => {
    counts()
    loadTop()
  })
  const needs = () => (counts()?.needsResponse ?? 0) > 0
  return HStack({ spacing: 4 }, [Icon(() => ((counts()?.open ?? 0) > 0 ? "tray.full" : "tray")).color(() => (needs() ? "warning" : "secondary")), UnseenBadge()])
    .paddingHorizontal(6)
    .cornerRadius(6)
    .hoverBackground("hover")
    .help(() => {
      const c = counts()
      if (!c || c.open === 0) return t("status.none", "Nothing needs you")
      return t("status.summary", "{unseen} unseen, {needs} need a response", { unseen: c.unseen, needs: c.needsResponse })
    })
    .onTap(() => {
      const list = menuItems()
      const next = list.find((i) => i.seenAt === null) ?? list[0]
      return next ? openItem(next) : undefined
    })
    .contextMenu(() => {
      const list = menuItems()
      return [
        ...(list.length
          ? list.map((i) => Button([kindLabel(i), i.title].filter(Boolean).join(": "), () => openItem(i)))
          : [Button(t("status.none", "Nothing needs you")).disabled()]),
        Divider(),
        Button(t("action.markAllSeen", "Mark All as Seen"), () => markAllSeen().catch((e: unknown) => noticeFor(describe(e))))
      ]
    })
}
