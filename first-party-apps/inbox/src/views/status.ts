/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The status item: a tray glyph with the badge (open requests, else unread
// items). Its menu lists the top items of the owner's urgent order; a click
// opens the first one. Its page follows the owner's op events like any list.

import { markAllRead, openItem } from "../actions.ts"
import { t } from "../l10n.ts"
import { counts, createFeedView } from "../store.ts"
import { CountBadge, kindLabel } from "./parts.ts"

const MENU_ITEMS = 8

export function StatusItem(): CmuxView {
  const top = createFeedView(() => ({ state: "open", order: "urgent", limit: MENU_ITEMS }))
  const waiting = () => (counts()?.open_requests ?? 0) > 0
  return HStack({ spacing: 4 }, [Icon(() => (top.items().length > 0 ? "tray.full" : "tray")).color(() => (waiting() ? "warning" : "secondary")), CountBadge()])
    .paddingHorizontal(6)
    .cornerRadius(6)
    .hoverBackground("hover")
    .help(() => {
      const c = counts()
      if (!c || (c.open_requests === 0 && c.unread === 0)) return t("status.none")
      return t("status.summary", { unread: c.unread, needs: c.open_requests })
    })
    .onTap(() => {
      const next = top.items()[0]
      return next ? openItem(next) : undefined
    })
    .contextMenu(() => {
      const list = top.items()
      return [
        ...(list.length ? list.map((i) => Button([kindLabel(i), i.title].filter(Boolean).join(": "), () => openItem(i))) : [Button(t("status.none")).disabled()]),
        Divider(),
        Button(t("action.markAllRead"), () => markAllRead())
      ]
    })
}
