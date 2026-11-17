// Calendar: the next events from the Mac's calendars, as Apple's Calendar "Up Next" widget.
// - small: the weekday in red over the big day number, then the next one or two events.
// - medium: the same on the left; the rest of today and then tomorrow on the right.
// - large: the rest of today on the left, tomorrow on the right.
// Each event is a block tinted with its calendar's color, a bar of that color on its leading edge.
// When nothing is left today it says so, as Apple does. On first install it asks for calendar access
// in place: one tap shows macOS's prompt, and the events follow.
//
// It imports nothing but the public SDK. Events come from the host op system_calendar.events
// (the Mac app reads EventKit; the daemon bounds and caches the read), re-read every 5 minutes and
// when the day changes; between reads the minute tick only drops events that have ended.

import {
  Button,
  cmux,
  effect,
  HStack,
  signal,
  Spacer,
  Text,
  VStack,
  WIDGET_INSET,
  type View,
  type WidgetContext
} from "cmux-extension-sdk"
import {
  agenda,
  barOf,
  dayNumber,
  readKey,
  READ,
  startTime,
  timeRange,
  tintOf,
  uses12Hour,
  weekdayHeading,
  type Access,
  type CalendarEvent,
  type Settings,
  type Size
} from "./calendar.ts"
import { SAMPLE_EVENTS } from "./sample.ts"

type Load =
  | { state: "loading" }
  | { state: "ready"; access: Access; events: CalendarEvent[] }
  | { state: "error"; code: string }

/** Apple's widget type scale for this layout, in points. */
const TYPE = { heading: 11, day: 34, title: 13, detail: 12, label: 11 } as const

/** Event blocks per column: what fits a tile at its height with Apple's three-line block. */
const BLOCKS: Record<Size, { left: number; right: number }> = {
  small: { left: 2, right: 0 },
  medium: { left: 1, right: 2 },
  large: { left: 5, right: 6 }
}

const t = (key: string, fallback: string, params?: Record<string, unknown>) => cmux.t(key, fallback, params)

export function renderCalendar(ctx: WidgetContext): View {
  const size: Size = ctx.size ?? "small"
  const settings = (ctx.settings ?? {}) as Settings
  const twelve = uses12Hour(cmux.app.locale || "en-US", settings.hourCycle)

  // The host ticks ctx.now on the minute while the tile is shown (cmux.widget/1).
  const now = () => ctx.now()

  const [load, setLoad] = signal<Load>(
    ctx.preview ? { state: "ready", access: "granted", events: SAMPLE_EVENTS(ctx.now()) } : { state: "loading" }
  )
  let readFor = ""
  const read = () => {
    cmux.system_calendar.events({ ...READ }).then(
      (answer) => setLoad({ state: "ready", access: answer.access, events: answer.events }),
      (error: { code?: string }) => setLoad({ state: "error", code: error?.code ?? "operation.failed" })
    )
  }
  if (!ctx.preview) {
    effect(() => {
      const key = readKey(now())
      if (key === readFor) return
      readFor = key
      read()
    })
  }
  // One tap shows macOS's prompt (the tap's gesture lets it); then read again.
  const allow = () => {
    cmux.system_calendar.request_access({}).then(read, read)
  }

  const inset = ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab
  const body = () => {
    const current = load()
    const at = now()
    const header = dateHeader(at)
    if (current.state !== "ready" || current.access !== "granted") {
      const notice = current.state === "loading" ? null : accessNotice(current, allow)
      return VStack({ spacing: 8, alignment: "leading" }, [header, notice, Spacer()])
    }
    const day = agenda(current.events, at)
    return layout(size, header, day, twelve)
  }
  return VStack({ alignment: "leading", spacing: 0 }, [body])
    .padding(inset)
    .frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" })
}

/** "TUESDAY" in red over the big "14". */
function dateHeader(at: number): View {
  return VStack({ spacing: 0, alignment: "leading" }, [
    Text(weekdayHeading(at)).font(TYPE.heading).weight("semibold").color("danger").lineLimit(1),
    Text(dayNumber(at)).font(TYPE.day).weight("regular").lineLimit(1)
  ])
}

/** What the widget says before it may read the calendar; the one button when a tap can fix it. */
function accessNotice(load: Exclude<Load, { state: "loading" }>, allow: () => void): View {
  const note = (text: string) => Text(text).font(TYPE.detail).color("secondary").lineLimit(4)
  if (load.state === "error") {
    if (load.code === "scope.missing") return note(t("scope", "Turn on calendar access for Calendar in Settings > Apps."))
    return note(
      load.code === "provider.unavailable" || load.code === "operation.unsupported"
        ? t("unavailable", "Your calendar shows here in the cmux app on a Mac.")
        : t("failed", "Your calendar could not be read just now.")
    )
  }
  switch (load.access) {
    case "unavailable":
      return note(t("unavailable", "Your calendar shows here in the cmux app on a Mac."))
    case "restricted":
      return note(t("restricted", "Calendar access is restricted on this Mac."))
    case "denied":
      return note(t("denied", "Calendar access is off. Turn it on for cmux in System Settings > Privacy & Security > Calendars."))
    default:
      return VStack({ spacing: 6, alignment: "leading" }, [
        note(t("ask", "See your next events here.")),
        Button(t("allow", "Allow Access"), allow)
      ])
  }
}

function layout(size: Size, header: View, day: ReturnType<typeof agenda>, twelve: boolean): View {
  const blocks = BLOCKS[size]
  const todayItems: Item[] = [
    ...day.allDayToday.map((e) => ({ kind: "allDay" as const, e })),
    ...day.today.map((e) => ({ kind: "timed" as const, e }))
  ]
  const tomorrowItems: Item[] = [
    ...day.allDayTomorrow.map((e) => ({ kind: "allDay" as const, e })),
    ...day.tomorrow.map((e) => ({ kind: "timed" as const, e }))
  ]
  const nothingToday = todayItems.length === 0
  const noMore = Text(t("noMoreToday", "No more events today")).font(TYPE.title).color("secondary").lineLimit(2)

  if (size === "small") {
    // A lone event keeps its place line; two share the tile as title and time.
    const shown = todayItems.slice(0, blocks.left)
    const rich = shown.length === 1
    return VStack({ spacing: 6, alignment: "leading" }, [
      header,
      nothingToday ? noMore : null,
      ...shown.map((item) => itemView(item, twelve, rich)),
      Spacer()
    ])
  }

  if (size === "medium") {
    const left = todayItems.slice(0, blocks.left)
    const rest = todayItems.slice(blocks.left)
    const right: View[] = []
    let room = blocks.right
    for (const item of rest.slice(0, room)) right.push(itemView(item, twelve, true))
    room -= Math.min(rest.length, room)
    if (room > 0 && tomorrowItems.length > 0) {
      right.push(dayLabel(t("tomorrow", "TOMORROW")))
      for (const item of tomorrowItems.slice(0, room)) right.push(itemView(item, twelve, true))
    } else if (nothingToday && tomorrowItems.length === 0) {
      right.push(dayLabel(t("tomorrow", "TOMORROW")))
      right.push(Text(t("noEventsTomorrow", "No events")).font(TYPE.detail).color("secondary"))
    }
    return HStack({ spacing: 12, alignment: "top" }, [
      column([header, nothingToday ? noMore : null, ...left.map((item) => itemView(item, twelve, true))]),
      column(right)
    ])
  }

  // large: the rest of today on the left, tomorrow on the right.
  const more = (count: number) =>
    count > 0 ? Text(t("more", "{count} more", { count })).font(TYPE.label).weight("semibold").color("secondary") : null
  const tomorrowColumn: Array<View | null> = [dayLabel(t("tomorrow", "TOMORROW")).padding({ top: 4, bottom: 14 })]
  if (tomorrowItems.length === 0) tomorrowColumn.push(Text(t("noEventsTomorrow", "No events")).font(TYPE.detail).color("secondary"))
  for (const item of tomorrowItems.slice(0, blocks.right)) tomorrowColumn.push(itemView(item, twelve, true))
  tomorrowColumn.push(more(tomorrowItems.length - blocks.right))
  return HStack({ spacing: 12, alignment: "top" }, [
    column([
      header,
      nothingToday ? noMore : null,
      ...todayItems.slice(0, blocks.left).map((item) => itemView(item, twelve, true)),
      more(todayItems.length - blocks.left)
    ]),
    column(tomorrowColumn)
  ])
}

type Item = { kind: "allDay" | "timed"; e: CalendarEvent }

function column(children: Array<View | null>): View {
  return VStack({ spacing: 6, alignment: "leading" }, [...children, Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" })
}

/** "TOMORROW", Apple's gray day label. */
function dayLabel(text: string): View {
  return Text(text).font(TYPE.label).weight("semibold").color("secondary").lineLimit(1)
}

function itemView(item: Item, twelve: boolean, rich: boolean): View {
  return item.kind === "allDay" ? allDayBlock(item.e) : eventBlock(item.e, twelve, rich)
}

/** An event: a bar in the calendar's color, then title, place and time, on the calendar's tint. */
function eventBlock(e: CalendarEvent, twelve: boolean, rich: boolean): View {
  const color = barOf(e.color)
  const lines: View[] = [Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1)]
  if (rich && e.location) lines.push(Text(e.location).font(TYPE.detail).color(color).lineLimit(1))
  lines.push(Text(rich ? timeRange(e, twelve) : startTime(e, twelve)).font(TYPE.detail).color(color).lineLimit(1))
  return block(color, e.color, VStack({ spacing: 0, alignment: "leading" }, lines))
}

/** An all-day event: its title alone on the tint, as Apple lists them above the day's times. */
function allDayBlock(e: CalendarEvent): View {
  const color = barOf(e.color)
  return block(color, e.color, Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1))
}

function block(bar: string, color: string, content: View): View {
  return HStack({ spacing: 6, alignment: "top" }, [
    VStack([]).frame({ width: 3, minHeight: 14, maxHeight: "infinity" }).background(bar).cornerRadius(1.5),
    content,
    Spacer()
  ])
    .padding({ top: 4, bottom: 4, leading: 5, trailing: 6 })
    .background(tintOf(color))
    .cornerRadius(6)
    .frame({ maxWidth: "infinity" })
}
