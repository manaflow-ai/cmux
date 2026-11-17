// Pure calendar logic: the read window, which events each size shows, and the text Apple's Calendar
// widget uses for them. No cmux calls here, so the tests run it directly.

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
export interface Settings {
  hourCycle?: HourCycle
}

const DAY = 24 * 60 * 60 * 1000
const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

/** Local midnight of the day `at` falls in. */
export function startOfDay(at: number): number {
  const d = new Date(at)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

/** Local midnight of the day after `at` (DST-safe: built from the date, not +24 h). */
export function startOfNextDay(at: number): number {
  const d = new Date(at)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime()
}

/** One read: the events from now through the end of tomorrow (two days from now always covers it). */
export const READ = { days: 2, limit: 50 } as const


/** "TUESDAY", Apple's red heading. */
export function weekdayHeading(now: number): string {
  return WEEKDAYS[new Date(now).getDay()]!.toUpperCase()
}

/** "14", the big day number. */
export function dayNumber(now: number): string {
  return String(new Date(now).getDate())
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
export function agenda(events: readonly CalendarEvent[], now: number): Agenda {
  const tomorrowStart = startOfNextDay(now)
  const tomorrowEnd = startOfNextDay(tomorrowStart)
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
function clock(at: number, twelve: boolean): { time: string; period: string } {
  const d = new Date(at)
  const h = d.getHours()
  const m = String(d.getMinutes()).padStart(2, "0")
  if (!twelve) return { time: `${String(h).padStart(2, "0")}:${m}`, period: "" }
  return { time: `${h % 12 === 0 ? 12 : h % 12}:${m}`, period: h < 12 ? "AM" : "PM" }
}

/** "4:00–5:00 PM", "11:30 AM–12:30 PM" or "16:00–17:00": Apple's range, the period once when shared. */
export function timeRange(e: Pick<CalendarEvent, "start" | "end">, twelve: boolean): string {
  const a = clock(e.start, twelve)
  const b = clock(e.end, twelve)
  if (!twelve) return `${a.time}–${b.time}`
  if (a.period === b.period && startOfDay(e.start) === startOfDay(e.end)) return `${a.time}–${b.time} ${b.period}`
  return `${a.time} ${a.period}–${b.time} ${b.period}`
}

/** "4:00 PM" or "16:00": an event's start alone (the large list). */
export function startTime(e: Pick<CalendarEvent, "start">, twelve: boolean): string {
  const a = clock(e.start, twelve)
  return twelve ? `${a.time} ${a.period}` : a.time
}

/** The calendar's color at the tint Apple puts behind an event (about 18 % over the tile). */
export function tintOf(color: string | undefined): string {
  return color && /^#[0-9a-fA-F]{6}$/.test(color) ? `${color}2e` : "#1badf82e"
}

/** A color the event's text and bar may use: the calendar's, else Calendar's default blue. */
export function barOf(color: string | undefined): string {
  return color && /^#[0-9a-fA-F]{6}$/.test(color) ? color : "#1badf8"
}

/** When to read again: on the first render, every 5 minutes, and when the day changes. */
export function readKey(now: number): string {
  return `${startOfDay(now)}:${Math.floor(now / (5 * 60 * 1000))}`
}

export { DAY }
