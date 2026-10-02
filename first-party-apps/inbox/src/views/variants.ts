/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The three dogfood variants of the main surface. `wide` is true in a pane
// (side-by-side layouts), false in the sidebar section.
//
// grouped: dense rows under source (or workspace) headers; a click opens.
// focus:   source chips, a flat list where a click selects, and a detail area.
// card:    one item at a time with Open / Done / Snooze / Skip.

import { markAllRead } from "../actions.ts"
import { t } from "../l10n.ts"
import type { Source } from "../model.ts"
import { current, filters, groups, selected, setFilters, setSelected, visible } from "../store.ts"
import { Actions, Detail, detailState, ReplyField, Summary } from "./detail.ts"
import { Empty, FilterMenu, GithubStatusRow, ItemRow, LayoutProbe, Notices, SnoozedFooter, sourceLabel, SOURCE_SYMBOLS, UnreadBadge } from "./parts.ts"

const groupTitle = (g: { source: Source | null; label: string }) => (g.source ? sourceLabel(g.source) : g.label)

function Toolbar(): CmuxView {
  return HStack({ spacing: 6 }, [
    FilterMenu(),
    Spacer(),
    UnreadBadge(),
    Button(Icon("checkmark.circle").color("secondary"), () => markAllRead()).help(t("action.markAllRead", "Mark All as Read"))
  ])
    .paddingHorizontal(12)
    .paddingVertical(2)
}

export function renderGrouped(wide: boolean): CmuxView {
  const root = VStack({ spacing: 2 }, [
    Toolbar(),
    Notices(),
    LayoutProbe(),
    ForEach({ items: groups, key: (g) => g.key }, (g) =>
      VStack({ spacing: 0 }, [
        HStack({ spacing: 4 }, [
          Text(() => groupTitle(g())).font("caption").weight("semibold").color("secondary").lineLimit(1),
          Spacer(),
          Text(() => String(g().items.length)).font("caption").color("tertiary")
        ])
          .paddingHorizontal(14)
          .padding({ top: 6, bottom: 2, leading: 14, trailing: 14 }),
        ForEach({ items: () => g().items, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: true }))
      ])
    ),
    GithubStatusRow(),
    Empty(),
    SnoozedFooter()
  ])
  return wide ? root.frame({ maxWidth: 720 }) : root
}

function Chip(symbol: string, label: string, active: () => boolean, action: () => unknown): CmuxView {
  return Button(Icon(symbol).font("caption").color(() => (active() ? "primary" : "secondary")), action)
    .padding(5)
    .background(() => (active() ? "selected" : null))
    .hoverBackground("hover")
    .cornerRadius(6)
    .help(label)
}

function ChipBar(): CmuxView {
  const sources: Array<"all" | Source> = ["all", "agent", "notification", "github"]
  return HStack({ spacing: 2 }, [
    ...sources.map((s) => Chip(SOURCE_SYMBOLS[s], sourceLabel(s), () => filters().source === s && !filters().showSnoozed, () => setFilters({ source: s, showSnoozed: false }))),
    Spacer(),
    Chip("envelope.badge", t("filter.unreadOnly", "Show Unread Only"), () => filters().unreadOnly, () => setFilters({ unreadOnly: !filters().unreadOnly })),
    Chip("person", t("filter.mineOnly", "Show Only My Work"), () => filters().mineOnly, () => setFilters({ mineOnly: !filters().mineOnly })),
    Chip("checkmark.circle", t("action.markAllRead", "Mark All as Read"), () => false, () => markAllRead())
  ]).paddingHorizontal(10)
}

export function renderFocus(wide: boolean): CmuxView {
  const detail = detailState()
  const list = VStack({ spacing: 2 }, [
    ChipBar(),
    Notices(),
    ForEach({ items: visible, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: false, selectedId: () => current()?.id ?? null, onSelect: setSelected })),
    GithubStatusRow(),
    Empty(),
    SnoozedFooter()
  ])
  // Stacks have no alignment prop, so each column ends in a Spacer to stay top-aligned in a pane of fixed height.
  if (wide) return HStack({ spacing: 0 }, [VStack([list, Spacer()]).frame({ width: 320, maxHeight: "infinity" }), Divider(), VStack([Detail(detail), Spacer()]).padding(16).frame({ maxWidth: "infinity", maxHeight: "infinity" })])
  return VStack({ spacing: 8 }, [list, Divider(), Detail(detail).paddingHorizontal(12)])
}

export function renderCard(wide: boolean): CmuxView {
  const detail = detailState()
  const position = computed(() => {
    const list = visible()
    const index = list.findIndex((i) => i.id === (selected() ?? list[0]?.id))
    return list.length ? t("card.position", "{index} of {total}", { index: Math.max(0, index) + 1, total: list.length }) : ""
  })
  const card = VStack({ spacing: 12 }, [Summary(detail, "title3"), Actions(detail, true), ReplyField(detail)])
    .padding(14)
    .background("hover")
    .borderColor("separator")
    .borderWidth(1)
    .cornerRadius(10)
  const root = VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [FilterMenu(), Spacer(), Text(position).font("caption").color("tertiary")]).paddingHorizontal(12),
    Notices(),
    Group([() => (detail.has() ? card : null)]).paddingHorizontal(10),
    GithubStatusRow(),
    Empty(),
    SnoozedFooter()
  ])
  return wide ? root.frame({ maxWidth: 560 }) : root
}
