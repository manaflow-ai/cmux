// Variant "quiet": nothing in the menu bar while every provider is on or
// under pace; a warning glyph and the ratio appear when one is over pace or
// out of usable accounts. The pane is a dense monospaced table (one text
// line per account); the section is one line per provider.

import { durationText, pctText, providerInitial, providerTitle, ratioText, stateText, verdictText } from "../format.ts"
import { t } from "../l10n.ts"
import type { Account, Provider } from "../model.ts"
import type { ProviderPace } from "../pace.ts"
import { weeklyPace } from "../pace.ts"
import { now, paceOf, paces, readingAt } from "../store.ts"
import { menuItems, NoticeLine, ProblemView, providerList, statusHelp, stateTone, paceTone, type Actions } from "./parts.ts"

const alarming = (p: ProviderPace) => p.metered && (p.verdict === "over" || p.verdict === "none" || p.usable === 0)

/** The status text while something needs attention, else null (the item stays empty). */
const hot = computed(() => {
  const list = paces().filter(alarming)
  if (list.length === 0) return null
  return list.map((p) => `${providerInitial(p.provider)} ${p.ratio !== null ? ratioText(p.ratio) : `${p.usable}/${p.total}`}`).join(" · ")
})

export function quietStatus(actions: Actions) {
  return HStack({ spacing: 0 }, [
    () => {
      const h = hot()
      if (!h) return null
      return HStack({ spacing: 3 }, [Icon("exclamationmark.triangle.fill").color("warning").size(11), Text(h).font("caption").monospaced().color("warning")])
        .help(statusHelp)
        .onTap(() => actions.show())
        .contextMenu(() => menuItems(actions))
    }
  ])
}

const cell = (s: string, width: number) => (s.length > width ? `${s.slice(0, width - 1)}…` : s.padEnd(width))
const short = (resetAt: number | null, at: number) => (resetAt === null ? "" : durationText(Math.max(0, resetAt - at)).replace(" ", ""))

/** "label                    in use     78% 2h10m   67% 2d4h   ×0.48". */
export function accountTableLine(a: Account, at: number, readAt: number): string {
  const session = a.session ? `${pctText(a.session.leftPct).padStart(4)} ${short(a.session.resetAt, at)}` : ""
  const weekly = a.weekly ? `${pctText(a.weekly.leftPct).padStart(4)} ${short(a.weekly.resetAt, at)}` : (a.plan ?? "")
  const pace = weeklyPace(a, readAt)
  return `${cell(a.label, 26)} ${cell(stateText(a.state), 9)} ${cell(session, 11)} ${cell(weekly, 11)} ${pace ? ratioText(pace.ratio) : ""}`.trimEnd()
}

function providerBlock(p: () => Provider) {
  const pace = () => paceOf(p().id)
  return VStack({ spacing: 1 }, [
    Text(() => {
      const x = pace()
      const verdict = x ? verdictText(x.verdict, x.metered) + (x.ratio !== null ? ` ${ratioText(x.ratio)}` : "") : ""
      return `${providerTitle(p().id)}  ${verdict}  ${p().summary.usable}/${p().summary.total}`
    })
      .font("caption")
      .weight("semibold")
      .monospaced()
      .color(() => paceTone(pace()))
      .padding({ top: 8, leading: 12, bottom: 2, trailing: 12 }),
    ForEach({ items: () => p().accounts, key: (a) => a.id }, (a) =>
      Text(() => accountTableLine(a(), now(), readingAt()))
        .font("caption2")
        .monospaced()
        .lineLimit(1)
        .color(() => (a().state === "cooked" || a().state === "error" || a().state === "temp" ? stateTone(a().state) : "primary"))
        .padding({ top: 0, leading: 12, bottom: 0, trailing: 12 })
    )
  ])
}

/** The column titles of the table. */
export const tableHeader = () =>
  `${cell(t("column.account", "account"), 26)} ${cell(t("column.state", "state"), 9)} ${cell(t("column.session", "5h"), 11)} ${cell(t("column.weekly", "week"), 11)} ${t("column.pace", "pace")}`

export function quietPane() {
  return VStack({ spacing: 0 }, [
    NoticeLine("caption"),
    () => ProblemView(),
    Text(tableHeader).font("caption2").monospaced().color("tertiary").padding({ top: 8, leading: 12, bottom: 0, trailing: 12 }),
    ForEach({ items: providerList, key: (p) => p.id }, (p) => providerBlock(p))])
}

export function quietSection(actions: Actions) {
  return VStack({ spacing: 1 }, [
    NoticeLine("caption2"),
    () => ProblemView(),
    ForEach({ items: providerList, key: (p) => p.id }, (p) => {
      const pace = () => paceOf(p().id)
      return Text(() => {
        const x = pace()
        const tail = x && x.metered ? (x.ratio !== null ? ratioText(x.ratio) : verdictText(x.verdict)) : ""
        return `${cell(providerTitle(p().id), 8)} ${cell(`${p().summary.usable}/${p().summary.total}`, 7)} ${tail}`.trimEnd()
      })
        .font("caption")
        .monospaced()
        .color(() => paceTone(pace()))
        .padding({ top: 1, leading: 12, bottom: 1, trailing: 12 })
        .onTap(() => actions.show())
    })
  ])
}
