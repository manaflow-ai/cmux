import { BigNumber, bySize, Caption, Headline, RowList, SPACE, Spacer, VStack, widget, WidgetEmpty, WidgetFrame, WidgetTitle } from "cmux-extension-sdk"

type Meeting = { id: string; title: string; start: number; room: string }

const SAMPLE: Meeting[] = [
  { id: "standup", title: "Standup", start: 9 * 60 + 30, room: "Zoom" },
  { id: "design", title: "Design review", start: 14 * 60, room: "4B" },
  { id: "call", title: "Customer call", start: 15 * 60 + 30, room: "Zoom" },
  { id: "retro", title: "Retro", start: 17 * 60, room: "2A" },
]

// In the Add Widget gallery, show the sample at 13:35 so "in 25 min" matches the sample.
const PREVIEW_NOW = 13 * 60 + 35

function minutesOfDay(ms: number): number {
  const d = new Date(ms)
  return d.getHours() * 60 + d.getMinutes()
}

function hhmm(minutes: number): string {
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return `${h < 10 ? "0" : ""}${h}:${m < 10 ? "0" : ""}${m}`
}

export const renderWidget = widget((ctx) => {
  const now = ctx.preview ? PREVIEW_NOW : minutesOfDay(ctx.now())
  const upcoming = SAMPLE.filter((m) => m.start >= now).sort((a, b) => a.start - b.start)
  const next = upcoming[0]

  if (!next) {
    return WidgetFrame(
      [WidgetEmpty("No more meetings", { message: "Free for the rest of today", symbol: "calendar" })],
      { place: ctx.place }
    )
  }

  const rest = upcoming.slice(1)
  const untilMin = next.start - now

  return WidgetFrame(
    [
      WidgetTitle("Calendar", { symbol: "calendar" }),
      bySize(ctx, {
        small: () =>
          VStack({ spacing: SPACE.xxs, alignment: "leading" }, [
            Spacer(),
            BigNumber(hhmm(next.start)),
            Headline(next.title),
            Caption(`in ${untilMin} min · ${next.room}`),
          ]),
        medium: () =>
          VStack({ spacing: SPACE.s, alignment: "leading" }, [
            Headline(next.title),
            Caption(`${hhmm(next.start)} · in ${untilMin} min · ${next.room}`),
            rest.length
              ? RowList(
                  () =>
                    rest.map((m) => ({
                      id: m.id,
                      title: m.title,
                      detail: m.room,
                      trailing: hhmm(m.start),
                    })),
                  { max: 3 }
                )
              : Caption("No more meetings today"),
          ]),
      }),
    ],
    { place: ctx.place }
  )
})
