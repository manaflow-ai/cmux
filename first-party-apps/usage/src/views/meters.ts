// Variant "meters": the menu bar shows one tiny bar per metered provider
// (weekly headroom left over all its accounts), tinted by the verdict. The
// pane shows a card per provider: a headroom bar, the summary line, and one
// line per account with session and weekly bars. The section shows the
// provider bars.

import { pctText, providerTitle, stateText, summaryText, windowText } from "../format.ts"
import { t } from "../l10n.ts"
import type { Account, Provider } from "../model.ts"
import { now, paceOf, state, stale } from "../store.ts"
import {
  accountTone,
  headroomShare,
  isCollapsed,
  menuItems,
  Meter,
  meteredPaces,
  NoticeLine,
  ProblemView,
  providerList,
  readingAt,
  sessionShare,
  stateTone,
  statusHelp,
  toggleCollapsed,
  verdictLabel,
  verdictTone,
  paceTone,
  weeklyShare,
  type Actions
} from "./parts.ts"

/** Card bar width: panes have no container width yet (README gap 4). */
export const CARD_METER_WIDTH = 320

export function metersStatus(actions: Actions) {
  return VStack({ spacing: 2 }, [
    ForEach({ items: () => meteredPaces().slice(0, 3), key: (p) => p.provider }, (p) =>
      Meter(() => headroomShare(p()), 22, 4, () => verdictTone(p().verdict))
    )
  ])
    .paddingVertical(3)
    .paddingHorizontal(3)
    .opacity(() => (stale() || state() !== "ready" ? 0.55 : 1))
    .help(statusHelp)
    .onTap(() => actions.show())
    .contextMenu(() => menuItems(actions))
}

/** A thin native bar, only while the window exists (the column keeps its width either way). */
function bar(share: () => number | null) {
  const has = computed(() => share() !== null)
  return () => (has() ? ProgressView(() => share() ?? 0) : null)
}

function accountLine(a: () => Account) {
  return HStack({ spacing: 8 }, [
    VStack({ spacing: 0 }, [
      Text(() => a().label)
        .font("caption")
        .lineLimit(1)
        .truncation("middle"),
      Text(() => stateText(a().state))
        .font("caption2")
        .color(() => stateTone(a().state))
    ]).frame({ width: 170, alignment: "leading" }),
    VStack({ spacing: 1 }, [bar(() => sessionShare(a())), Text(() => windowText(a().session, now()) ?? "").font("caption2").secondary()]).frame({ maxWidth: "infinity", alignment: "leading" }),
    VStack({ spacing: 1 }, [
      bar(() => weeklyShare(a())),
      Text(() => windowText(a().weekly, now()) ?? (a().plan ?? ""))
        .font("caption2")
        .color(() => accountTone(a(), readingAt()))
    ]).frame({ maxWidth: "infinity", alignment: "leading" })
  ]).padding({ top: 3, leading: 12, bottom: 3, trailing: 12 })
}

function providerCard(p: () => Provider) {
  const pace = () => paceOf(p().id)
  const open = computed(() => !isCollapsed(p().id))
  const metered = computed(() => pace()?.metered === true)
  return VStack({ spacing: 4 }, [
    VStack({ spacing: 4 }, [
      HStack({ spacing: 6 }, [
        Text(() => providerTitle(p().id)).font("headline"),
        Spacer(),
        Text(() => verdictLabel(pace()))
          .font("caption")
          .weight("semibold")
          .color(() => paceTone(pace()))
      ]),
      // Hidden for keyed providers (no weekly window to measure).
      Meter(() => headroomShare(pace()), CARD_METER_WIDTH, 6, () => paceTone(pace())).opacity(() => (metered() ? 1 : 0)),
      Text(() => {
        const x = pace()
        if (!x) return ""
        return x.metered ? `${summaryText(x, false)} · ${t("summary.left", "{left} left", { left: pctText(x.leftSumPct) })}` : summaryText(x)
      })
        .font("caption")
        .secondary()
        .lineLimit(2)
    ])
      .padding({ top: 10, leading: 12, bottom: 4, trailing: 12 })
      .cursor("pointer")
      .onTap(() => toggleCollapsed(p().id)),
    () => (open() ? ForEach({ items: () => p().accounts, key: (a) => a.id }, (a) => accountLine(a)) : null)
  ])
}

export function metersPane() {
  return VStack({ spacing: 6 }, [NoticeLine("caption"), () => ProblemView(), ForEach({ items: providerList, key: (p) => p.id }, (p) => providerCard(p))])
}

export function metersSection(actions: Actions) {
  return VStack({ spacing: 6 }, [
    NoticeLine("caption2"),
    () => ProblemView(),
    ForEach({ items: providerList, key: (p) => p.id }, (p) => {
      const pace = () => paceOf(p().id)
      const metered = computed(() => pace()?.metered === true)
      return VStack({ spacing: 3 }, [
        HStack({ spacing: 4 }, [
          Text(() => providerTitle(p().id)).font("caption"),
          Spacer(),
          Text(() => `${p().summary.usable}/${p().summary.total}`)
            .font("caption")
            .monospaced()
            .secondary()
        ]),
        () => (metered() ? ProgressView(() => headroomShare(pace())) : null),
        Text(() => verdictLabel(pace()))
          .font("caption2")
          .color(() => paceTone(pace()))
      ])
        .padding({ top: 2, leading: 12, bottom: 2, trailing: 12 })
        .onTap(() => actions.show())
    })
  ])
}
