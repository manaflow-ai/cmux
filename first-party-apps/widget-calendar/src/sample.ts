// The events the Add Widget gallery shows (ctx.preview): a plausible day around `now`, never the
// person's own calendar. The tests and the gallery fixtures use the same day.

import { localOffset, startOfDay, startOfNextDay, type CalendarEvent, type Offset } from "./calendar.ts"

const HOUR = 60 * 60 * 1000

/** `hour:minute` on the day `day` falls in, in the zone. */
function at(day: number, hour: number, minute: number, off: Offset): number {
  return startOfDay(day, off) + hour * HOUR + minute * 60_000
}

/** Calendar's own default colors: Work blue, Home green, Family purple. */
export const COLORS = { work: "#1badf8", home: "#63da38", family: "#cc73e1", birthdays: "#ff9500" } as const

export function event(
  id: string,
  title: string,
  start: number,
  minutes: number,
  calendar: keyof typeof COLORS,
  location?: string
): CalendarEvent {
  return {
    id,
    title,
    start,
    end: start + minutes * 60 * 1000,
    allDay: false,
    calendar: calendar[0]!.toUpperCase() + calendar.slice(1),
    color: COLORS[calendar],
    ...(location ? { location } : {})
  }
}

export function allDay(id: string, title: string, day: number, calendar: keyof typeof COLORS, off: Offset = localOffset): CalendarEvent {
  const start = startOfDay(day, off)
  return {
    id,
    title,
    start,
    end: startOfNextDay(start, off) - 1000,
    allDay: true,
    calendar: calendar[0]!.toUpperCase() + calendar.slice(1),
    color: COLORS[calendar]
  }
}

/** A Tuesday-ish day: two events left today, two tomorrow. */
export function SAMPLE_EVENTS(now: number, off: Offset = localOffset): CalendarEvent[] {
  const today = startOfDay(now, off)
  const tomorrow = startOfNextDay(today, off)
  return [
    event("yoga", "Yoga Class", at(today, 16, 0, off), 60, "family", "Golden Gate Park"),
    event("dinner", "Dinner with Ravi", at(today, 18, 0, off), 90, "home", "Nopa"),
    event("coffee", "Pick up coffee", at(tomorrow, 8, 30, off), 30, "home", "Coffee Shop"),
    event("standup", "Team standup", at(tomorrow, 10, 0, off), 15, "work", "Zoom")
  ]
}
