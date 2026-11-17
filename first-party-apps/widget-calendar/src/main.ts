// Calendar: the next events from the Mac's calendars, as Apple's Calendar "Up Next" widget.
// - small: the weekday in red over the big day number, then the next one or two events.
// - medium: the same on the left; the rest of today and then tomorrow on the right.
// - large: Apple's hour grid, today from the current hour with the red now line, tomorrow from an
//   hour before its first event (the setting "largeLayout": "list" lists the next events instead).
// Each event is a block tinted with its calendar's color, a bar of that color on its leading edge.
// When nothing is left today it says so, as Apple does. On first install it asks for calendar access
// in place: one tap shows macOS's prompt, and the events follow.
//
// It imports nothing but the public SDK. Events come from the watch source system_calendar.events
// (the Mac app reads EventKit; the daemon bounds and caches the read, and pushes
// system_calendar.changed when a calendar changes, so the tile redraws at once). Times are in the
// person's zone (ctx.timeZone through cmux.time.zone: the sandbox has no Intl) and clock
// (ctx.locale, or the hourCycle setting); the minute tick only drops events that have ended.

import {
  Button,
  Circle,
  cmux,
  HStack,
  Line,
  Spacer,
  Text,
  VStack,
  WIDGET_INSET,
  ZStack,
  type View,
  type WidgetContext
} from "cmux-extension-sdk"
import {
  agenda,
  barOf,
  CALENDAR_RED,
  dayNumber,
  gridColumn,
  hourLabel,
  localOffset,
  READ,
  startOfDay,
  startOfNextDay,
  startTime,
  timeRange,
  tintOf,
  uses12Hour,
  weekdayHeading,
  type Access,
  type CalendarEvent,
  type GridColumn,
  type Offset,
  type Settings,
  type Size
} from "./calendar.ts"
import { SAMPLE_EVENTS } from "./sample.ts"

type Load =
  | { state: "loading" }
  | { state: "ready"; access: Access; events: CalendarEvent[] }
  | { state: "error"; code: string }

/** Apple's widget type scale for this layout, in points. */
const TYPE = { heading: 11, day: 32, title: 13, detail: 12, label: 11, hour: 11 } as const

/** The large hour grid, in points: an hour's height, the hour labels' gutter, the day label row. */
const GRID = { hour: 36, gutter: 20, label: 16, hours: 7 } as const

/** Event blocks per column: what fits a tile at its height with Apple's three-line block. */
const BLOCKS: Record<Size, { left: number; right: number }> = {
  small: { left: 2, right: 0 },
  medium: { left: 1, right: 2 },
  large: { left: 5, right: 6 }
}

const t = (key: string, fallback: string, params?: Record<string, unknown>) => cmux.t(key, fallback, params)

/** The person's zone as an Offset: cmux.time.zone per quarter hour (zones change on the hour), the
 * process's own zone when the host names none or does not know it. */
export function zoneOffset(zone: string | undefined): Offset {
  if (!zone) return localOffset
  const cache = new Map<number, number>()
  return (at) => {
    const key = Math.floor(at / 900_000)
    let minutes = cache.get(key)
    if (minutes === undefined) {
      try {
        minutes = cmux.time.zone(zone, at).offsetMinutes
      } catch {
        minutes = localOffset(at)
      }
      if (cache.size > 256) cache.clear()
      cache.set(key, minutes)
    }
    return minutes
  }
}

export function renderCalendar(ctx: WidgetContext): View {
  const size: Size = ctx.size ?? "small"
  const settings = (ctx.settings ?? {}) as Settings
  const twelve = uses12Hour(ctx.locale || cmux.app.locale || "en-US", settings.hourCycle)
  const off = zoneOffset(ctx.timeZone)
  const grid = size === "large" && settings.largeLayout !== "list"

  // The host ticks ctx.now on the minute while the tile is shown (cmux.widget/1).
  const now = () => ctx.now()

  // One shared, cached read; it re-reads when a calendar changes (system_calendar.changed).
  const live = ctx.preview ? null : cmux.watch("system_calendar.events", { ...READ })
  const sample: Load = { state: "ready", access: "granted", events: SAMPLE_EVENTS(ctx.now(), off) }
  const load = (): Load => {
    if (!live) return sample
    // A failed re-read keeps the last answer (the watch serves it stale); only no answer at all shows the error.
    const answer = live.value()
    const error = live.error()
    if (!answer && error) return { state: "error", code: error.code ?? "operation.failed" }
    if (!answer) return { state: "loading" }
    return { state: "ready", access: answer.access as Access, events: (answer.events ?? []) as CalendarEvent[] }
  }
  // One tap shows macOS's prompt (the tap's gesture lets it); then read again.
  const allow = () => {
    const again = () => live?.refresh()
    cmux.system_calendar.request_access({}).then(again, again)
  }

  const inset = ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab
  const body = () => {
    const current = load()
    const at = now()
    const header = dateHeader(at, off, grid)
    if (current.state !== "ready" || current.access !== "granted") {
      const notice = current.state === "loading" ? null : accessNotice(current, allow)
      return VStack({ spacing: 8, alignment: "leading" }, [header, notice, Spacer()])
    }
    if (grid) return hourGrid(header, current.events, at, off, twelve)
    return layout(size, header, agenda(current.events, at, off), twelve, off)
  }
  return VStack({ alignment: "leading", spacing: 0 }, [body])
    .padding(inset)
    .frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" })
}

/** "TUESDAY" in Calendar's red over the big "14". On the grid it takes a label row and an hour, so
 * today's hours line up with tomorrow's. */
function dateHeader(at: number, off: Offset, grid = false): View {
  const view = VStack({ spacing: 0, alignment: "leading" }, [
    Text(weekdayHeading(at, off)).font(TYPE.heading).weight("semibold").color(CALENDAR_RED).lineLimit(1),
    Text(dayNumber(at, off)).font(TYPE.day).weight("regular").lineLimit(1)
  ])
  return grid ? view.frame({ height: GRID.label + GRID.hour, alignment: "topLeading" }) : view
}

/** Apple's large widget: today's hours from now on the left under the date, tomorrow's on the right. */
function hourGrid(header: View, events: readonly CalendarEvent[], at: number, off: Offset, twelve: boolean): View {
  const day = agenda(events, at, off)
  const todayStart = startOfDay(at, off)
  const tomorrowStart = startOfNextDay(at, off)
  const allDay = day.allDayToday.length > 0 || day.allDayTomorrow.length > 0
  // An all-day row takes an hour of both columns, so the hours stay level.
  const hours = GRID.hours - (allDay ? 1 : 0)
  const allDayRow = (list: CalendarEvent[]) =>
    allDay
      ? VStack({ spacing: 2, alignment: "leading" }, [
          ...list.slice(0, 1).map((e) => allDayBlock(e)),
          list.length > 1 ? Text(t("more", "{count} more", { count: list.length - 1 })).font(TYPE.label).color("secondary") : null
        ]).frame({ maxWidth: "infinity", height: GRID.hour, alignment: "topLeading" })
      : null
  const today = gridColumn(day.today, todayStart, hours - 1, off, at)
  const tomorrow = gridColumn(day.tomorrow, tomorrowStart, hours, off)
  return HStack({ spacing: 14, alignment: "top" }, [
    VStack({ spacing: 0, alignment: "leading" }, [header, allDayRow(day.allDayToday), gridView(today, twelve, off, day.today.length === 0 ? t("noMoreToday", "No more events today") : null)]).frame({
      maxWidth: "infinity",
      alignment: "topLeading"
    }),
    VStack({ spacing: 0, alignment: "leading" }, [
      dayLabel(t("tomorrow", "TOMORROW")).frame({ height: GRID.label, alignment: "topLeading" }),
      allDayRow(day.allDayTomorrow),
      gridView(tomorrow, twelve, off, day.tomorrow.length === 0 ? t("noEventsTomorrow", "No events") : null)
    ]).frame({ maxWidth: "infinity", alignment: "topLeading" })
  ]).frame({ maxWidth: "infinity", alignment: "topLeading" })
}

/** One column: an hour label and hairline per hour, each event a tinted block at its time (overlaps
 * share the width), the red now line. Rows fill the width; blocks and the line are offset from the
 * ZStack's center, so no point width is assumed. */
function gridView(column: GridColumn, twelve: boolean, off: Offset, empty: string | null = null): View {
  const height = (column.endHour - column.startHour) * GRID.hour + 1
  const y = (hour: number) => (hour - column.startHour) * GRID.hour
  const rows: View[] = []
  for (let hour = column.startHour; hour <= column.endHour; hour++) {
    rows.push(
      HStack({ spacing: 0, alignment: "top" }, [
        Text(hourLabel(hour, twelve))
          .font(TYPE.hour)
          .weight("semibold")
          .color("secondary")
          .lineLimit(1)
          .frame({ width: GRID.gutter, alignment: "leading" })
          .offset({ y: -7 }),
        Line({ stroke: "separator" }).frame({ maxWidth: "infinity" })
      ]).frame({ maxWidth: "infinity", height: hour === column.endHour ? 1 : GRID.hour, alignment: "topLeading" })
    )
  }
  const children: View[] = [VStack({ spacing: 0, alignment: "leading" }, rows).frame({ maxWidth: "infinity" })]
  // Nothing timed left in the column: Apple's words over the empty hours, past the labels.
  if (empty)
    children.push(
      HStack({ spacing: 0 }, [VStack([]).frame({ width: GRID.gutter }), Text(empty).font(TYPE.title).color("secondary").lineLimit(2), Spacer()]).frame({ maxWidth: "infinity" })
    )
  for (const b of column.blocks) {
    const h = Math.max(16, (b.to - b.from) * GRID.hour - 2)
    const lanes: View[] = []
    for (let lane = 0; lane < b.lanes; lane++)
      lanes.push(lane === b.lane ? gridBlock(b.e, h, twelve, off) : VStack([]).frame({ maxWidth: "infinity", height: h }))
    children.push(
      HStack({ spacing: 2, alignment: "top" }, [VStack([]).frame({ width: GRID.gutter - 2 }), ...lanes])
        .frame({ maxWidth: "infinity", height: h })
        .offset({ y: y(b.from) + 1 + h / 2 - height / 2 })
    )
  }
  if (column.now !== undefined) {
    children.push(
      HStack({ spacing: 0, alignment: "center" }, [
        VStack([]).frame({ width: GRID.gutter - 3 }),
        Circle({ fill: CALENDAR_RED, size: 6 }),
        Line({ stroke: CALENDAR_RED, strokeWidth: 1.5 }).frame({ maxWidth: "infinity" })
      ])
        .frame({ maxWidth: "infinity", height: 6 })
        .offset({ y: y(column.now) - height / 2 })
    )
  }
  return ZStack(children).frame({ maxWidth: "infinity", height })
}

/** An event on the grid: title, then its start and place as the height allows, as Apple's block. */
function gridBlock(e: CalendarEvent, height: number, twelve: boolean, off: Offset): View {
  const color = barOf(e.color)
  const lines: View[] = [Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1)]
  if (height >= 34) lines.push(Text(startTime(e, twelve, off)).font(TYPE.detail).color(color).lineLimit(1))
  if (height >= 50 && e.location) lines.push(Text(e.location).font(TYPE.detail).color(color).lineLimit(1))
  return HStack({ spacing: 5, alignment: "top" }, [
    VStack([]).frame({ width: 3, maxHeight: "infinity" }).background(color).cornerRadius(1.5),
    VStack({ spacing: 0, alignment: "leading" }, lines),
    Spacer()
  ])
    .padding({ top: 3, bottom: 3, leading: 4, trailing: 4 })
    .background(tintOf(e.color))
    .cornerRadius(5)
    .frame({ maxWidth: "infinity", height, alignment: "topLeading" })
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

function layout(size: Size, header: View, day: ReturnType<typeof agenda>, twelve: boolean, off: Offset): View {
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
      ...shown.map((item) => itemView(item, twelve, rich, off)),
      Spacer()
    ])
  }

  if (size === "medium") {
    const left = todayItems.slice(0, blocks.left)
    const rest = todayItems.slice(blocks.left)
    const right: View[] = []
    let room = blocks.right
    for (const item of rest.slice(0, room)) right.push(itemView(item, twelve, true, off))
    room -= Math.min(rest.length, room)
    if (room > 0 && tomorrowItems.length > 0) {
      right.push(dayLabel(t("tomorrow", "TOMORROW")))
      for (const item of tomorrowItems.slice(0, room)) right.push(itemView(item, twelve, true, off))
    } else if (nothingToday && tomorrowItems.length === 0) {
      right.push(dayLabel(t("tomorrow", "TOMORROW")))
      right.push(Text(t("noEventsTomorrow", "No events")).font(TYPE.detail).color("secondary"))
    }
    return HStack({ spacing: 12, alignment: "top" }, [
      column([header, nothingToday ? noMore : null, ...left.map((item) => itemView(item, twelve, true, off))]),
      column(right)
    ]).frame({ maxWidth: "infinity", alignment: "topLeading" })
  }

  // large as a list (the setting): the rest of today on the left, tomorrow on the right.
  const more = (count: number) =>
    count > 0 ? Text(t("more", "{count} more", { count })).font(TYPE.label).weight("semibold").color("secondary") : null
  const tomorrowColumn: Array<View | null> = [dayLabel(t("tomorrow", "TOMORROW")).padding({ top: 4, bottom: 14 })]
  if (tomorrowItems.length === 0) tomorrowColumn.push(Text(t("noEventsTomorrow", "No events")).font(TYPE.detail).color("secondary"))
  for (const item of tomorrowItems.slice(0, blocks.right)) tomorrowColumn.push(itemView(item, twelve, true, off))
  tomorrowColumn.push(more(tomorrowItems.length - blocks.right))
  return HStack({ spacing: 12, alignment: "top" }, [
    column([
      header,
      nothingToday ? noMore : null,
      ...todayItems.slice(0, blocks.left).map((item) => itemView(item, twelve, true, off)),
      more(todayItems.length - blocks.left)
    ]),
    column(tomorrowColumn)
  ]).frame({ maxWidth: "infinity", alignment: "topLeading" })
}

type Item = { kind: "allDay" | "timed"; e: CalendarEvent }

function column(children: Array<View | null>): View {
  return VStack({ spacing: 6, alignment: "leading" }, [...children, Spacer()]).frame({ maxWidth: "infinity", maxHeight: "infinity", alignment: "topLeading" })
}

/** "TOMORROW", Apple's gray day label. */
function dayLabel(text: string): View {
  return Text(text).font(TYPE.label).weight("semibold").color("secondary").lineLimit(1)
}

function itemView(item: Item, twelve: boolean, rich: boolean, off: Offset): View {
  return item.kind === "allDay" ? allDayBlock(item.e) : eventBlock(item.e, twelve, rich, off)
}

/** An event: a bar in the calendar's color, then title, place and time, on the calendar's tint. */
function eventBlock(e: CalendarEvent, twelve: boolean, rich: boolean, off: Offset): View {
  const color = barOf(e.color)
  const lines: View[] = [Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1)]
  if (rich && e.location) lines.push(Text(e.location).font(TYPE.detail).color(color).lineLimit(1))
  lines.push(Text(rich ? timeRange(e, twelve, off) : startTime(e, twelve, off)).font(TYPE.detail).color(color).lineLimit(1))
  return block(color, e.color, VStack({ spacing: 0, alignment: "leading" }, lines))
}

/** An all-day event: its title alone on the tint, as Apple lists them above the day's times. */
function allDayBlock(e: CalendarEvent): View {
  const color = barOf(e.color)
  return block(color, e.color, Text(e.title || t("untitled", "New Event")).font(TYPE.title).weight("medium").lineLimit(1))
}

function block(bar: string, color: string | undefined, content: View): View {
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
