// Pure calendar logic: the read window, which events each size shows, where they sit on the hour
// grid, and the text Apple's Calendar widget uses for them. No cmux calls here, so the tests run it
// directly.
//
// Every wall-clock answer (the day, the hour, "4:00 PM") is in the person's time zone, given as an
// `Offset`: the sandbox has no Intl, so main.ts builds it from `cmux.time.zone(ctx.timeZone, at)`.
// With none, the process's own zone is used (`localOffset`).

/** One event as the host answers it (`system_calendar.events`). */
export interface CalendarEvent {
  id: string
  title: string
  /** Unix ms */
  start: number
  /** Unix ms */
  end: number
  allDay: boolean
  calendar: string
  /** The calendar's color, `#rrggbb`, when the host sends one. */
  color?: string
  location?: string
  url?: string
}

export type Access = "granted" | "notDetermined" | "denied" | "restricted" | "unavailable"
export type Size = "small" | "medium" | "large"
export type HourCycle = "system" | "12h" | "24h"
/** The large size: Apple's hour grid (today and tomorrow) or the list of the next events. */
export type LargeLayout = "grid" | "list"
export interface Settings {
  hourCycle?: HourCycle
  largeLayout?: LargeLayout
}

/** Minutes east of UTC at an instant (Unix ms): the person's zone, DST included. */
export type Offset = (at: number) => number

/** The process's own zone (a fallback when the host names none). */
export const localOffset: Offset = (at) => -new Date(at).getTimezoneOffset()

/** A fixed offset (tests and zones with no DST). */
export const fixedOffset = (minutes: number): Offset => () => minutes

const DAY = 24 * 60 * 60 * 1000
const HOUR = 60 * 60 * 1000
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

/** The wall clock at `at` in the zone, read with the getUTC* methods. */
export function wall(at: number, off: Offset = localOffset): Date {
  return new Date(at + off(at) * 60_000)
}

/** The instant a wall-clock time (as UTC fields) happens in the zone; `near` guesses the offset. */
function fromWall(wallMs: number, off: Offset, near: number): number {
  const guess = wallMs - off(near) * 60_000
  return wallMs - off(guess) * 60_000
}

/** Midnight of the day `at` falls in, in the zone. */
export function startOfDay(at: number, off: Offset = localOffset): number {
  const w = wall(at, off)
  return fromWall(Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate()), off, at)
}

/** Midnight of the day after `at` (DST-safe: built from the date, not +24 h). */
export function startOfNextDay(at: number, off: Offset = localOffset): number {
  const w = wall(at, off)
  return fromWall(Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate() + 1), off, at + DAY)
}

/** Hours since the midnight of `dayStart` (9.5 is 9:30), in the zone's wall clock. */
export function hourOfDay(at: number, dayStart: number, off: Offset = localOffset): number {
  return (at + off(at) * 60_000 - (dayStart + off(dayStart) * 60_000)) / HOUR
}

/** One read: the events from now through the end of tomorrow (two days from now always covers it). */
export const READ = { days: 2, limit: 50 } as const

/** "TUESDAY", Apple's red heading. */
export function weekdayHeading(now: number, off: Offset = localOffset): string {
  return WEEKDAYS[wall(now, off).getUTCDay()]!.toUpperCase()
}

/** "14", the big day number. */
export function dayNumber(now: number, off: Offset = localOffset): string {
  return String(wall(now, off).getUTCDate())
}

/** What each size shows. */
export interface Agenda {
  /** Today's all-day events (Apple lists them first, title only). */
  allDayToday: CalendarEvent[]
  /** Today's timed events that have not ended, in start order. */
  today: CalendarEvent[]
  /** Tomorrow's all-day events. */
  allDayTomorrow: CalendarEvent[]
  /** Tomorrow's timed events. */
  tomorrow: CalendarEvent[]
}

/** Splits the answer into today (not yet ended) and tomorrow, as Apple's Up Next does. */
export function agenda(events: readonly CalendarEvent[], now: number, off: Offset = localOffset): Agenda {
  const tomorrowStart = startOfNextDay(now, off)
  const tomorrowEnd = startOfNextDay(tomorrowStart, off)
  const out: Agenda = { allDayToday: [], today: [], allDayTomorrow: [], tomorrow: [] }
  const sorted = [...events].sort((a, b) => a.start - b.start || a.end - b.end || a.title.localeCompare(b.title))
  for (const e of sorted) {
    if (e.allDay) {
      if (e.start < tomorrowStart && e.end > now) out.allDayToday.push(e)
      if (e.start < tomorrowEnd && e.end > tomorrowStart) out.allDayTomorrow.push(e)
      continue
    }
    if (e.end <= now) continue
    if (e.start < tomorrowStart) out.today.push(e)
    else if (e.start < tomorrowEnd) out.tomorrow.push(e)
  }
  return out
}

/** Whether `locale` reads time on a 12-hour clock (Apple's default per region, roughly). */
export function uses12Hour(locale: string, cycle: HourCycle = "system"): boolean {
  if (cycle !== "system") return cycle === "12h"
  const region = (locale.split(/[-_]/)[1] ?? "").toUpperCase()
  const language = (locale.split(/[-_]/)[0] ?? "en").toLowerCase()
  if (region) return ["US", "CA", "AU", "NZ", "IN", "PH", "PK", "EG", "SA", "MX", "CO"].includes(region)
  return language === "en"
}

/** "4:00" (12 h, the period apart) or "16:00". */
export function clock(at: number, twelve: boolean, off: Offset = localOffset): { time: string; period: string } {
  const d = wall(at, off)
  const h = d.getUTCHours()
  const m = String(d.getUTCMinutes()).padStart(2, "0")
  if (!twelve) return { time: `${String(h).padStart(2, "0")}:${m}`, period: "" }
  return { time: `${h % 12 === 0 ? 12 : h % 12}:${m}`, period: h < 12 ? "AM" : "PM" }
}

/** "4:00–5:00 PM", "11:30 AM–12:30 PM" or "16:00–17:00": Apple's range, the period once when shared. */
export function timeRange(e: Pick<CalendarEvent, "start" | "end">, twelve: boolean, off: Offset = localOffset): string {
  const a = clock(e.start, twelve, off)
  const b = clock(e.end, twelve, off)
  if (!twelve) return `${a.time}–${b.time}`
  if (a.period === b.period && startOfDay(e.start, off) === startOfDay(e.end, off)) return `${a.time}–${b.time} ${b.period}`
  return `${a.time} ${a.period}–${b.time} ${b.period}`
}

/** "4:00 PM" or "16:00": an event's start alone (the large list). */
export function startTime(e: Pick<CalendarEvent, "start">, twelve: boolean, off: Offset = localOffset): string {
  const a = clock(e.start, twelve, off)
  return twelve ? `${a.time} ${a.period}` : a.time
}

/** "1" … "12" on a 12-hour clock, "13" on a 24-hour one: the grid's hour labels, as Apple's. */
export function hourLabel(hour: number, twelve: boolean): string {
  const h = ((hour % 24) + 24) % 24
  return twelve ? String(h % 12 === 0 ? 12 : h % 12) : String(h)
}

const HEX = /^#[0-9a-fA-F]{6}$/

/** The calendar's color at the tint Apple puts behind an event (about 18 % over the tile). */
export function tintOf(color: string | undefined): string {
  return color && HEX.test(color) ? `${color}2e` : "#1badf82e"
}

/** A color the event's text and bar may use: the calendar's, else Calendar's default blue. */
export function barOf(color: string | undefined): string {
  return color && HEX.test(color) ? color : "#1badf8"
}

/** Apple's red for the weekday heading and the now line (a hex, not the theme's accent). */
export const CALENDAR_RED = "#ff3b30"

/** One event on a column of the hour grid: its hours on that day, clipped to the column. */
export interface GridBlock {
  e: CalendarEvent
  /** Hours of the day (9.5 is 9:30), within [startHour, endHour]. */
  from: number
  to: number
  lane: number
  lanes: number
}

/** One column of Apple's large hour grid: the hours it shows and the events on them. */
export interface GridColumn {
  startHour: number
  endHour: number
  blocks: GridBlock[]
  /** The now line, in hours of the day, when it falls in the column. */
  now?: number
}

/**
 * Today's column starts at the current hour (Apple: "1" with the red line at 1:12) and shows
 * `hours`; tomorrow's starts an hour before its first event (7 for an 8:30 coffee), else at 7.
 * Both stay within the day.
 */
export function gridColumn(
  events: readonly CalendarEvent[],
  dayStart: number,
  hours: number,
  off: Offset = localOffset,
  now?: number
): GridColumn {
  const at = (e: number) => hourOfDay(e, dayStart, off)
  let first: number
  if (now !== undefined) first = Math.floor(at(now))
  else {
    const earliest = events.length > 0 ? Math.min(...events.map((e) => at(e.start))) : 8
    first = Math.floor(Math.max(0, earliest)) - 1
  }
  const startHour = Math.max(0, Math.min(24 - hours, first))
  const endHour = startHour + hours
  const shown = events
    .map((e) => ({ e, from: Math.max(startHour, at(e.start)), to: Math.min(endHour, at(e.end)) }))
    .filter((b) => b.to > b.from)
    .sort((a, b) => a.from - b.from || b.to - a.to)
  const blocks = lanes(shown)
  const column: GridColumn = { startHour, endHour, blocks }
  if (now !== undefined) {
    const h = at(now)
    if (h >= startHour && h <= endHour) column.now = h
  }
  return column
}

/** Overlapping events share the width: each takes the first lane free at its start, and every
 * event in one overlapping run gets that run's lane count (Apple's day view does the same). */
function lanes(sorted: Array<{ e: CalendarEvent; from: number; to: number }>): GridBlock[] {
  const out: GridBlock[] = []
  let run: GridBlock[] = []
  let runEnd = -Infinity
  let ends: number[] = []
  const close = () => {
    for (const b of run) b.lanes = Math.max(1, ends.length)
    run = []
    ends = []
  }
  for (const s of sorted) {
    if (s.from >= runEnd) {
      close()
      runEnd = -Infinity
    }
    let lane = ends.findIndex((end) => end <= s.from)
    if (lane < 0) lane = ends.push(s.to) - 1
    else ends[lane] = s.to
    const block: GridBlock = { ...s, lane, lanes: 1 }
    run.push(block)
    out.push(block)
    runEnd = Math.max(runEnd, s.to)
  }
  close()
  return out
}

export { DAY }
