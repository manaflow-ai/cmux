// Variant "sidebarOnly": no menu bar presence while every limit is calm; the
// status item appears only as a warning (a limit at a threshold or on pace
// to run out). Usage lives in a dense sidebar section: one line per window
// with a native progress bar.

import { durationText, percentText, windowLabel } from "../format.ts"
import { percentOf, type UsageAccount, type UsageWindow } from "../model.ts"
import { paceOf } from "../pace.ts"
import { allAccounts, now } from "../store.ts"
import { accountStale, accountTitle, menuItems, NoteLine, ProblemView, severity, textTone, toneOf, top, windowDetail } from "./parts.ts"
import { statusHelp, type Actions } from "./percent.ts"

/** The window to warn about in the status item, or null to show nothing. */
const hot = computed(() => {
  const tt = top()
  if (!tt || accountStale(tt.account)) return null
  return severity(tt.window, now()) === "normal" ? null : JSON.stringify({ percent: tt.percent, tone: toneOf(severity(tt.window, now())) })
})

export function quietStatus(actions: Actions) {
  return HStack({ spacing: 0 }, [
    () => {
      const h = hot()
      if (!h) return null
      const { percent, tone } = JSON.parse(h) as { percent: number; tone: string }
      return HStack({ spacing: 3 }, [Icon("exclamationmark.triangle.fill").color(tone).size(11), Text(percentText(percent)).font("caption").monospaced().color(tone)])
        .help(statusHelp)
        .onTap(() => actions.show())
        .contextMenu(() => menuItems(actions))
    }
  ])
}

/** "2h 10m" until the reset, or the spend, for the end of a dense line. */
function shortTail(w: UsageWindow, at: number): string {
  const p = paceOf(w, at)
  if (p?.runsOutAt) return `↓ ${durationText(Math.max(0, p.runsOutAt - at))}`
  if (w.resetsAt !== null) return durationText(Math.max(0, w.resetsAt - at))
  return ""
}

function windowLine(account: () => UsageAccount, w: () => UsageWindow) {
  return HStack({ spacing: 6 }, [
    Text(() => windowLabel(w()))
      .font("caption")
      .lineLimit(1)
      .frame({ width: 72 }),
    ProgressView(() => Math.min(1, (percentOf(w()) ?? 0) / 100)).frame({ maxWidth: "infinity" }),
    Text(() => percentText(percentOf(w())))
      .font("caption")
      .monospaced()
      .color(() => (accountStale(account()) ? "tertiary" : textTone(severity(w(), now()))))
      .frame({ width: 34 }),
    Text(() => shortTail(w(), now()))
      .font("caption2")
      .color(() => (paceOf(w(), now())?.runsOutAt ? "warning" : "secondary"))
      .lineLimit(1)
      .frame({ width: 58 })
  ])
    .padding({ top: 1, leading: 12, bottom: 1, trailing: 12 })
    .help(() => windowDetail(w(), now()))
}

function accountLines(a: () => UsageAccount) {
  return VStack({ spacing: 2 }, [
    VStack({ spacing: 1 }, [
      Text(() => accountTitle(a()))
        .font("caption2")
        .secondary()
        .lineLimit(1),
      NoteLine(a, "caption2")
    ]).padding({ top: 6, leading: 12, bottom: 0, trailing: 12 }),
    ForEach({ items: () => a().windows, key: (w) => w.id }, (w) => windowLine(a, w))
  ]).opacity(() => (accountStale(a()) ? 0.7 : 1))
}

export function quietDetail() {
  return VStack({ spacing: 2 }, [() => ProblemView(), ForEach({ items: allAccounts, key: (a) => a.id }, (a) => accountLines(a))]).padding({ top: 0, leading: 0, bottom: 6, trailing: 0 })
}
