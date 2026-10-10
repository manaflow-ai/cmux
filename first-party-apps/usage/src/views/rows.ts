// Variant "rows" (recommended): the menu bar shows each metered provider's
// burn ratio ("C ×0.92 · X ×1.31") behind a gauge glyph tinted by the worst
// verdict; a click opens a dropdown with one summary line per provider. The
// pane groups native rows per provider under a summary line; the sidebar
// section is one row per provider.

import { providerTitle, ratioText, stateText, summaryText } from "../format.ts"
import { t } from "../l10n.ts"
import type { Account, Provider } from "../model.ts"
import { now, paceOf, readingAt, state, stale } from "../store.ts"
import {
  accountBadge,
  accountDetail,
  isCollapsed,
  menuItems,
  meteredPaces,
  NoticeLine,
  paceToken,
  ProblemView,
  providerList,
  STATE_SYMBOL,
  stateTone,
  statusHelp,
  toggleCollapsed,
  verdictLabel,
  verdictTone,
  paceTone,
  worstVerdict,
  type Actions
} from "./parts.ts"

export function rowsStatus(actions: Actions) {
  const title = () => meteredPaces().map(paceToken).join(" · ") || "—"
  return HStack({ spacing: 3 }, [
    Icon(() => (worstVerdict() === "over" || worstVerdict() === "none" ? "gauge.with.needle.fill" : "gauge.with.needle"))
      .color(() => verdictTone(worstVerdict()))
      .size(11),
    // The dropdown: a Menu node whose items are live (README gap 5).
    Menu(title, []).contextMenu(() => menuItems(actions))
  ])
    .opacity(() => (stale() || state() !== "ready" ? 0.55 : 1))
    .help(statusHelp)
}

function accountRow(a: () => Account) {
  return Row({
    title: () => a().label,
    subtitle: () => [stateText(a().state), accountDetail(a(), now(), readingAt())].filter(Boolean).join(" · "),
    badge: () => accountBadge(a()),
    tint: () => stateTone(a().state),
    symbol: () => STATE_SYMBOL[a().state]
  })
}

function providerHeader(p: () => Provider) {
  const pace = () => paceOf(p().id)
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Icon(() => (isCollapsed(p().id) ? "chevron.right" : "chevron.down"))
        .size(9)
        .color("tertiary"),
      Text(() => providerTitle(p().id)).font("headline"),
      Spacer(),
      Badge(() => verdictLabel(pace()), () => paceTone(pace()))
    ]),
    Text(() => {
      const x = pace()
      return x ? summaryText(x, false) : ""
    })
      .font("caption")
      .secondary()
      .lineLimit(2)
  ])
    .padding({ top: 10, leading: 12, bottom: 4, trailing: 12 })
    .cursor("pointer")
    .onTap(() => toggleCollapsed(p().id))
}

function providerGroup(p: () => Provider) {
  const open = computed(() => !isCollapsed(p().id))
  return VStack({ spacing: 0 }, [
    providerHeader(p),
    () => (open() ? ForEach({ items: () => p().accounts, key: (a) => a.id }, (a) => accountRow(a)) : null)
  ])
}

export function rowsPane() {
  return VStack({ spacing: 0 }, [NoticeLine("caption"), () => ProblemView(), ForEach({ items: providerList, key: (p) => p.id }, (p) => providerGroup(p))])
}

export function rowsSection(actions: Actions) {
  return VStack({ spacing: 0 }, [
    NoticeLine("caption2"),
    () => ProblemView(),
    ForEach({ items: providerList, key: (p) => p.id }, (p) => {
      const pace = () => paceOf(p().id)
      return Row({
        title: () => providerTitle(p().id),
        subtitle: () => {
          const x = pace()
          return x && x.ratio !== null ? `${verdictLabel(x)} ${ratioText(x.ratio)}` : verdictLabel(x)
        },
        badge: () => t("usableBadge", "{usable}/{total}", { usable: p().summary.usable, total: p().summary.total }),
        tint: () => paceTone(pace()),
        symbol: "gauge.with.needle"
      }).onTap(() => actions.show())
    })
  ])
}
