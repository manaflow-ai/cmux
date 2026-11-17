// The events the Add Widget gallery shows (ctx.preview): a plausible day around `now`, never the
// person's own calendar. The tests and the gallery fixtures use the same day.

import { startOfDay, type CalendarEvent } from "./calendar.ts"

const HOUR = 60 * 60 * 1000

function at(day: number, hour: number, minute = 0): number {
  const d = new Date(day)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), hour, minute).getTime()
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

export function allDay(id: string, title: string, day: number, calendar: keyof typeof COLORS): CalendarEvent {
  const start = startOfDay(day)
  const d = new Date(start)
  return {
    id,
    title,
    start,
    end: new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime() - 1000,
    allDay: true,
    calendar: calendar[0]!.toUpperCase() + calendar.slice(1),
    color: COLORS[calendar]
  }
}

/** A Monday-ish day: two events left today, two tomorrow. */
export function SAMPLE_EVENTS(now: number): CalendarEvent[] {
  const today = startOfDay(now)
  const tomorrow = today + 26 * HOUR
  return [
    event("yoga", "Yoga Class", at(today, 16), 60, "family", "Golden Gate Park"),
    event("dinner", "Dinner with Ravi", at(today, 18), 90, "home", "Nopa"),
    event("coffee", "Pick up coffee", at(tomorrow, 8, 30), 30, "home", "Coffee Shop"),
    event("standup", "Team standup", at(tomorrow, 10), 15, "work", "Zoom")
  ]
}
