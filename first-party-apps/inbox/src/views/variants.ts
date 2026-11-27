/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// The three dogfood variants of the main surface. `wide` is true in a pane
// (side-by-side layouts), false in the sidebar section.
//
// grouped: dense rows under the owner's groups (poster, workspace, thread); a click opens.
// focus:   filter chips, a flat list where a click selects, and a detail area with the answer form.
// card:    one item at a time with its answer form and its actions.

import { markAllRead, markRead } from "../actions.ts"
import type { FeedItem } from "../feed.ts"
import { t } from "../l10n.ts"
import { createFeedView, filters, groupsOf, mainParams, selected, setFilters, setSelected, SOURCES, type FeedView, type SourceFilter } from "../store.ts"
import { Actions, AnswerForm, Detail, detailState, Summary } from "./detail.ts"
import { CountBadge, DoneFooter, Empty, FilterMenu, ItemRow, Notices, sourceLabel, workspaceNames } from "./parts.ts"

function Toolbar(): CmuxView {
  return HStack({ spacing: 6 }, [FilterMenu(), Spacer(), CountBadge(), Button(Icon("checkmark.circle").color("secondary"), () => markAllRead()).help(t("action.markAllRead"))])
    .paddingHorizontal(12)
    .paddingVertical(2)
}

/** The selected item of `view` (the first one when nothing is selected). */
const currentOf = (view: FeedView) => computed<FeedItem | null>(() => view.items().find((i) => i.id === selected()) ?? view.items()[0] ?? null)

/** Selecting is opening the item in this surface: it counts as read. */
const select = (i: FeedItem) => {
  setSelected(i.id)
  return markRead([i])
}

export function renderGrouped(wide: boolean): CmuxView {
  const view = createFeedView(mainParams, { primary: true })
  const workspace = workspaceNames()
  const groups = groupsOf(view)
  const root = VStack({ spacing: 2 }, [
    Toolbar(),
    Notices(),
    ForEach({ items: groups, key: (g) => g.key }, (g) =>
      VStack({ spacing: 0 }, [
        Group([
          () =>
            g().key !== "all"
              ? HStack({ spacing: 4 }, [
                  Text(() => workspace(g().label) || g().label || t("group.none")).font("caption").weight("semibold").color("secondary").lineLimit(1),
                  Spacer(),
                  Text(() => String(g().items.length)).font("caption").color("tertiary")
                ]).padding({ top: 6, bottom: 2, leading: 14, trailing: 14 })
              : null
        ]),
        ForEach({ items: () => g().items, key: (i) => i.id }, (i) => ItemRow(i, workspace, { tapOpens: true }))
      ])
    ),
    Empty(view),
    DoneFooter()
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

const CHIP_SYMBOLS: Record<SourceFilter, string> = { all: "tray", agent: "sparkles", integration: "link", automation: "play.circle", app: "app", system: "gearshape" }

function ChipBar(): CmuxView {
  return HStack({ spacing: 2 }, [
    ...SOURCES.map((s) => Chip(CHIP_SYMBOLS[s], sourceLabel(s), () => filters().source === s, () => setFilters({ source: s }))),
    Spacer(),
    Chip("hand.raised", t("filter.needsResponse"), () => filters().needsResponseOnly, () => setFilters({ needsResponseOnly: !filters().needsResponseOnly })),
    Chip("envelope.badge", t("filter.unreadOnly"), () => filters().unreadOnly, () => setFilters({ unreadOnly: !filters().unreadOnly })),
    Chip("checkmark.circle", t("action.markAllRead"), () => false, () => markAllRead())
  ]).paddingHorizontal(10)
}

export function renderFocus(wide: boolean): CmuxView {
  const view = createFeedView(mainParams, { primary: true })
  const workspace = workspaceNames()
  const current = currentOf(view)
  const detail = detailState(current, workspace)
  const list = VStack({ spacing: 2 }, [
    ChipBar(),
    Notices(),
    ForEach({ items: view.items, key: (i) => i.id }, (i) => ItemRow(i, workspace, { tapOpens: false, selectedId: () => current()?.id ?? null, onSelect: select })),
    Empty(view),
    DoneFooter()
  ])
  // Stacks have no alignment prop, so each column ends in a Spacer to stay top-aligned in a pane of fixed height.
  if (wide) return HStack({ spacing: 0 }, [VStack([list, Spacer()]).frame({ width: 320, maxHeight: "infinity" }), Divider(), VStack([Detail(detail), Spacer()]).padding(16).frame({ maxWidth: "infinity", maxHeight: "infinity" })])
  return VStack({ spacing: 8 }, [list, Divider(), Detail(detail).paddingHorizontal(12)])
}

export function renderCard(wide: boolean): CmuxView {
  const view = createFeedView(mainParams, { primary: true })
  const workspace = workspaceNames()
  const current = currentOf(view)
  const detail = detailState(current, workspace)
  const position = computed(() => {
    const list = view.items()
    const index = list.findIndex((i) => i.id === current()?.id)
    return list.length ? t("card.position", { index: Math.max(0, index) + 1, total: list.length }) : ""
  })
  const card = VStack({ spacing: 12 }, [Summary(detail, "title3"), AnswerForm(detail), Actions(detail, true)])
    .padding(14)
    .background("hover")
    .borderColor("separator")
    .borderWidth(1)
    .cornerRadius(10)
  const root = VStack({ spacing: 8 }, [
    HStack({ spacing: 6 }, [FilterMenu(), Spacer(), Text(position).font("caption").color("tertiary")]).paddingHorizontal(12),
    Notices(),
    Group([() => (detail.has() ? card : null)]).paddingHorizontal(10),
    Empty(view),
    DoneFooter()
  ])
  return wide ? root.frame({ maxWidth: 560 }) : root
}
