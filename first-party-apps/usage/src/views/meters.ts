// Variant "menuMeters": the menu bar shows a glyph of two tiny stacked meters
// (session over week) of the account with the tightest limit; a click opens
// a card popover (rendered today as the sidebar section; README gap 1). Each
// card has a meter per window with a tick where a steady pace would be.

import { percentText, windowLabel } from "../format.ts"
import { percentOf, sessionAndWeek, type UsageAccount, type UsageWindow } from "../model.ts"
import { allAccounts, now, state } from "../store.ts"
import { accountStale, menuItems, Meter, NoteLine, ProblemView, severity, textTone, top, windowDetail } from "./parts.ts"
import { statusHelp, topStale, type Actions } from "./percent.ts"

/** Width of a card's meter: the section is about 280 pt wide and there is no container width yet (README gap 4). */
export const CARD_METER_WIDTH = 240

export function metersStatus(actions: Actions) {
  const pair = () => {
    const tt = top()
    return tt ? sessionAndWeek(tt.account) : { session: null, week: null }
  }
  return VStack({ spacing: 2 }, [Meter(() => pair().session ?? top()?.window ?? null, 22, 4, false), Meter(() => pair().week, 22, 4, false)])
    .paddingVertical(3)
    .paddingHorizontal(3)
    .opacity(() => (topStale() || state() !== "ready" ? 0.55 : 1))
    .help(statusHelp)
    .onTap(() => actions.show())
    .contextMenu(() => menuItems(actions))
}

function windowCard(account: () => UsageAccount, w: () => UsageWindow) {
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 4 }, [
      Text(() => windowLabel(w())).font("caption"),
      Spacer(),
      Text(() => percentText(percentOf(w())))
        .font("caption")
        .monospaced()
        .weight("semibold")
        .color(() => (accountStale(account()) ? "tertiary" : textTone(severity(w(), now()))))
    ]),
    Meter(w, CARD_METER_WIDTH, 5, true),
    Text(() => windowDetail(w(), now()))
      .font("caption2")
      .secondary()
      .lineLimit(1)
  ])
}

function accountCard(a: () => UsageAccount) {
  return VStack({ spacing: 8 }, [
    VStack({ spacing: 1 }, [
      HStack({ spacing: 4 }, [
        Text(() => a().providerTitle)
          .font("headline")
          .lineLimit(1),
        Spacer(),
        Text(() => a().plan ?? "")
          .font("caption")
          .secondary()
          .lineLimit(1)
      ]),
      Text(() => a().label ?? "")
        .font("caption")
        .secondary()
        .lineLimit(1),
      NoteLine(a, "caption")
    ]),
    ForEach({ items: () => a().windows, key: (w) => w.id }, (w) => windowCard(a, w))
  ])
    .padding(10)
    .background("hover")
    .cornerRadius(8)
    .opacity(() => (accountStale(a()) ? 0.75 : 1))
}

export function metersDetail() {
  return VStack({ spacing: 8 }, [() => ProblemView(), ForEach({ items: allAccounts, key: (a) => a.id }, (a) => accountCard(a))]).padding({ top: 4, leading: 12, bottom: 8, trailing: 12 })
}
