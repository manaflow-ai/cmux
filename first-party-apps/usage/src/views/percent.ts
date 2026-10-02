// Variant "menuPercent": the menu bar shows the tightest limit as "62%" with a
// gauge glyph; a click opens a plain dropdown of every window. The detail
// view (sidebar section, and the dropdown's future popover) is native rows.

import { percentText, windowLabel } from "../format.ts"
import { t } from "../l10n.ts"
import type { UsageAccount, UsageWindow } from "../model.ts"
import { allAccounts, now, state } from "../store.ts"
import { accountStale, accountTitle, menuItems, NoteLine, percentLabel, ProblemView, severity, toneOf, top, windowDetail } from "./parts.ts"

export interface Actions {
  refresh: () => unknown
  show: () => unknown
}

const SYMBOLS: Record<string, string> = {
  session: "timer",
  daily: "sun.max",
  weekly: "calendar",
  monthly: "calendar",
  budget: "dollarsign.circle",
  credits: "creditcard",
  other: "gauge.with.dots.needle.50percent"
}

export function statusHelp(): string {
  const tt = top()
  if (!tt) return t("menu.noData", "No usage data")
  return t("status.help", "{provider} · {window} · {percent}", { provider: accountTitle(tt.account), window: windowLabel(tt.window), percent: percentText(tt.percent) })
}

export const topStale = () => {
  const tt = top()
  return tt ? accountStale(tt.account) : false
}

export function percentStatus(actions: Actions) {
  const tone = () => {
    const tt = top()
    return tt ? toneOf(severity(tt.window, now())) : "tertiary"
  }
  return HStack({ spacing: 3 }, [
    Icon(() => (tone() === "danger" ? "gauge.with.needle.fill" : "gauge.with.needle")).color(tone).size(11),
    // The dropdown: a Menu node whose items are live (README gap 5).
    Menu(() => (top() ? percentText(top()!.percent) : "—"), []).contextMenu(() => menuItems(actions))
  ])
    .opacity(() => (topStale() || state() !== "ready" ? 0.55 : 1))
    .help(statusHelp)
}

function windowRow(account: () => UsageAccount, w: () => UsageWindow) {
  return Row({
    title: () => windowLabel(w()),
    subtitle: () => windowDetail(w(), now()) || null,
    badge: () => percentLabel(w()),
    tint: () => (accountStale(account()) ? "tertiary" : toneOf(severity(w(), now()))),
    symbol: () => SYMBOLS[w().kind] ?? SYMBOLS.other!
  })
}

function accountBlock(a: () => UsageAccount) {
  return VStack({ spacing: 0 }, [
    VStack({ spacing: 1 }, [
      Text(() => accountTitle(a()))
        .font("caption")
        .secondary()
        .lineLimit(1),
      NoteLine(a, "caption2")
    ]).padding({ top: 6, leading: 12, bottom: 2, trailing: 12 }),
    ForEach({ items: () => a().windows, key: (w) => w.id }, (w) => windowRow(a, w))
  ]).opacity(() => (accountStale(a()) ? 0.7 : 1))
}

export function percentDetail() {
  return VStack({ spacing: 2 }, [() => ProblemView(), ForEach({ items: allAccounts, key: (a) => a.id }, (a) => accountBlock(a))])
}
