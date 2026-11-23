import { BigNumber, bySize, Caption, Gauge, Label, RowList, SPACE, Spacer, VStack, widget, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

const FOCUS_MINUTES = 25
const MINUTES_LEFT = 17
const CURRENT_BLOCK = 2
const BLOCKS_IN_CYCLE = 4
const DONE_TODAY = [
  { id: "1", title: "Focus 1", trailing: "09:00", done: true },
  { id: "2", title: "Focus 2", trailing: "10:30", done: true },
]

export const renderWidget = widget((ctx) => {
  const progress = (FOCUS_MINUTES - MINUTES_LEFT) / FOCUS_MINUTES
  return WidgetFrame(
    [
      WidgetTitle("Focus", { symbol: "timer" }),
      bySize(ctx, {
        small: () =>
          VStack({ spacing: SPACE.xxs, alignment: "leading" }, [
            Spacer(),
            BigNumber(String(MINUTES_LEFT)),
            Caption(`min left · block ${CURRENT_BLOCK} of ${BLOCKS_IN_CYCLE}`),
          ]),
        medium: () =>
          VStack({ spacing: SPACE.s, alignment: "leading" }, [
            Label(`${MINUTES_LEFT} min left`),
            Gauge(() => progress, { label: `block ${CURRENT_BLOCK} of ${BLOCKS_IN_CYCLE}` }),
            Caption("Done today"),
            RowList(() => DONE_TODAY, { max: 3 }),
          ]),
      }),
    ],
    { place: ctx.place }
  )
})
