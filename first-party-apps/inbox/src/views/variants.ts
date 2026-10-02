/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The three dogfood variants of the main surface. `wide` is true in a pane
// (side-by-side layouts), false in the sidebar section.
//
// grouped: dense rows under the owner's groups (source, workspace, thread); a click opens.
// focus:   filter chips, a flat list where a click selects, and a detail area with the response form.
// card:    one item at a time with its response form and Open / Done / Snooze / Skip.

import { markAllSeen } from "../actions.ts"
import { t } from "../l10n.ts"
import { attachList, current, filters, groups, items, selected, setFilters, setSelected, type SourceFilter } from "../store.ts"
import { Actions, Detail, detailState, ResponseForm, Summary } from "./detail.ts"
import { Empty, FilterMenu, filterLabel, ItemRow, Notices, SnoozedFooter, sourceKindLabel, UnseenBadge } from "./parts.ts"

function Toolbar(): CmuxView {
  return HStack({ spacing: 6 }, [
    FilterMenu(),
    Spacer(),
    UnseenBadge(),
    Button(Icon("checkmark.circle").color("secondary"), () => markAllSeen()).help(t("action.markAllSeen", "Mark All as Seen"))
  ])
    .paddingHorizontal(12)
    .paddingVertical(2)
}

export function renderGrouped(wide: boolean): CmuxView {
  attachList(true)
  const root = VStack({ spacing: 2 }, [
    Toolbar(),
    Notices(),
    ForEach({ items: groups, key: (g) => g.key }, (g) =>
      VStack({ spacing: 0 }, [
        Group([
          () =>
            g().label || g().sourceKind
              ? HStack({ spacing: 4 }, [
                  Text(() => (g().sourceKind && g().key === g().sourceKind ? sourceKindLabel(g().sourceKind!) : g().label)).font("caption").weight("semibold").color("secondary").lineLimit(1),
                  Spacer(),
                  Text(() => String(g().items.length)).font("caption").color("tertiary")
                ]).padding({ top: 6, bottom: 2, leading: 14, trailing: 14 })
              : null
        ]),
        ForEach({ items: () => g().items, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: true }))
      ])
    ),
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

const CHIP_SYMBOLS: Record<SourceFilter, string> = { all: "tray", agent: "sparkles", integration: "link", other: "square.grid.2x2" }

function ChipBar(): CmuxView {
  const sources: SourceFilter[] = ["all", "agent", "integration", "other"]
  return HStack({ spacing: 2 }, [
    ...sources.map((s) => Chip(CHIP_SYMBOLS[s], filterLabel(s), () => filters().source === s && !filters().showSnoozed, () => setFilters({ source: s, showSnoozed: false }))),
    Spacer(),
    Chip("hand.raised", t("filter.needsResponse", "Show Only What Needs a Response"), () => filters().needsResponseOnly, () => setFilters({ needsResponseOnly: !filters().needsResponseOnly })),
    Chip("envelope.badge", t("filter.unseenOnly", "Show Unseen Only"), () => filters().unseenOnly, () => setFilters({ unseenOnly: !filters().unseenOnly })),
    Chip("checkmark.circle", t("action.markAllSeen", "Mark All as Seen"), () => false, () => markAllSeen())
  ]).paddingHorizontal(10)
}

export function renderFocus(wide: boolean): CmuxView {
  attachList(false)
  const detail = detailState()
  const list = VStack({ spacing: 2 }, [
    ChipBar(),
    Notices(),
    ForEach({ items, key: (i) => i.id }, (i) => ItemRow(i, { tapOpens: false, selectedId: () => current()?.id ?? null, onSelect: setSelected })),
    Empty(),
    SnoozedFooter()
  ])
  // Stacks have no alignment prop, so each column ends in a Spacer to stay top-aligned in a pane of fixed height.
  if (wide) return HStack({ spacing: 0 }, [VStack([list, Spacer()]).frame({ width: 320, maxHeight: "infinity" }), Divider(), VStack([Detail(detail), Spacer()]).padding(16).frame({ maxWidth: "infinity", maxHeight: "infinity" })])
  return VStack({ spacing: 8 }, [list, Divider(), Detail(detail).paddingHorizontal(12)])
}

export function renderCard(wide: boolean): CmuxView {
  attachList(false)
  const detail = detailState()
  const position = computed(() => {
    const list = items()
    const index = list.findIndex((i) => i.id === (selected() ?? list[0]?.id))
    return list.length ? t("card.position", "{index} of {total}", { index: Math.max(0, index) + 1, total: list.length }) : ""
  })
  const card = VStack({ spacing: 12 }, [Summary(detail, "title3"), ResponseForm(detail), Actions(detail, true)])
    .padding(14)
    .background("hover")
    .borderColor("separator")
    .borderWidth(1)
    .cornerRadius(10)
  const root = VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [FilterMenu(), Spacer(), Text(position).font("caption").color("tertiary")]).paddingHorizontal(12),
    Notices(),
    Group([() => (detail.has() ? card : null)]).paddingHorizontal(10),
    Empty(),
    SnoozedFooter()
  ])
  return wide ? root.frame({ maxWidth: 560 }) : root
}
