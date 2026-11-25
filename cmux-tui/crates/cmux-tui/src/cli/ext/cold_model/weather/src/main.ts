import { BigNumber, bySize, Caption, RowList, SPACE, Spacer, VStack, widget, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

const CITY = "Lisbon"
const NOW = { temp: 21, condition: "Sunny", high: 24, low: 15 }
const NEXT_TEMPS = [22, 23, 23, 22]

export const renderWidget = widget((ctx) => {
  const hour = new Date(ctx.now()).getHours()
  const hours = NEXT_TEMPS.map((temp, i) => ({
    id: String(i + 1),
    title: `${String((hour + i + 1) % 24).padStart(2, "0")}:00`,
    trailing: `${temp}°`,
  }))

  return WidgetFrame(
    [
      WidgetTitle(CITY, { symbol: "sun.max" }),
      bySize(ctx, {
        small: () =>
          VStack({ spacing: SPACE.xxs, alignment: "leading" }, [
            Spacer(),
            BigNumber(`${NOW.temp}°`),
            Caption(`${NOW.condition} · H ${NOW.high}° L ${NOW.low}°`),
          ]),
        medium: () =>
          VStack({ spacing: SPACE.s, alignment: "leading" }, [
            Caption(`${NOW.condition} · H ${NOW.high}° L ${NOW.low}°`),
            RowList(() => hours, { max: 4 }),
          ]),
      }),
    ],
    { place: ctx.place }
  )
})
