/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The status item: a tray glyph with the unread count. A click opens the most
// urgent unread item; the menu lists what needs you.

import { markAllRead, openItem } from "../actions.ts"
import { t } from "../l10n.ts"
import { counts, items, refreshGithub } from "../store.ts"
import { kindLabel, UnreadBadge } from "./parts.ts"

const MENU_ITEMS = 8

const open = () => items().filter((i) => i.snoozedUntil === null)

export function StatusItem(): CmuxView {
  return HStack({ spacing: 4 }, [
    Icon(() => (counts().open > 0 ? "tray.full" : "tray")).color(() => (counts().blocked > 0 ? "warning" : "secondary")),
    UnreadBadge()
  ])
    .paddingHorizontal(6)
    .cornerRadius(6)
    .hoverBackground("hover")
    .help(() => (counts().unread > 0 ? t("badge.unread", "{n} unread", { n: counts().unread }) : t("status.none", "Nothing needs you")))
    .onTap(() => {
      const next = open().find((i) => i.unread) ?? open()[0]
      return next ? openItem(next) : undefined
    })
    .contextMenu(() => {
      const list = open().slice(0, MENU_ITEMS)
      return [
        ...(list.length
          ? list.map((i) => Button(`${kindLabel(i.kind)}: ${i.title}`, () => openItem(i)))
          : [Button(t("status.none", "Nothing needs you")).disabled()]),
        Divider(),
        Button(t("action.markAllRead", "Mark All as Read"), () => markAllRead()),
        Button(t("action.refresh", "Refresh"), () => refreshGithub(true))
      ]
    })
}
