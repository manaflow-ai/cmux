process.env.TZ = "America/Los_Angeles"
import { describe, expect, test } from "bun:test"
import { agenda, barOf, readKey, READ, startOfNextDay, timeRange, startTime, tintOf, uses12Hour, weekdayHeading, dayNumber, type CalendarEvent } from "../src/calendar.ts"

const NOW = new Date(2026, 10, 17, 13, 12).getTime() // Tuesday 1:12 PM
const local = (d: number, h: number, m = 0) => new Date(2026, 10, 17 + d, h, m).getTime()
const ev = (id: string, start: number, minutes: number, allDay = false): CalendarEvent => ({
  id, title: id, start, end: start + minutes * 60_000, allDay, calendar: "Work", color: "#1badf8"
})

describe("calendar logic", () => {
  test("the header is Apple's: weekday in capitals, the day number", () => {
    expect(weekdayHeading(NOW)).toBe("TUESDAY")
    expect(dayNumber(NOW)).toBe("17")
  })

  test("one read covers the rest of today and all of tomorrow", () => {
    expect(NOW + READ.days * 86_400_000).toBeGreaterThanOrEqual(local(2, 0))
    expect(READ.limit).toBeLessThanOrEqual(50)
  })

  test("the window holds across the November DST change (a 25 hour day)", () => {
    const sunday = new Date(2026, 10, 1, 9).getTime()
    expect(startOfNextDay(sunday)).toBe(new Date(2026, 10, 2).getTime())
  })

  test("ended events drop; an event in progress stays; tomorrow is split off", () => {
    const day = agenda([ev("past", local(0, 9), 30), ev("now", local(0, 13), 60), ev("later", local(0, 16), 60), ev("tmrw", local(1, 8), 30)], NOW)
    expect(day.today.map((e) => e.id)).toEqual(["now", "later"])
    expect(day.tomorrow.map((e) => e.id)).toEqual(["tmrw"])
  })

  test("all-day events list apart, on each day they cover", () => {
    const twoDays = { ...ev("trip", local(0, 0), 0, true), end: local(2, 0) - 1000 }
    const day = agenda([twoDays, ev("bday", local(1, 0), 24 * 60 - 1, true)], NOW)
    expect(day.allDayToday.map((e) => e.id)).toEqual(["trip"])
    expect(day.allDayTomorrow.map((e) => e.id)).toEqual(["trip", "bday"])
    expect(day.today).toEqual([])
  })

  test("times read as Apple writes them", () => {
    expect(timeRange(ev("a", local(0, 16), 60), true)).toBe("4:00–5:00 PM")
    expect(timeRange(ev("b", local(0, 11, 30), 60), true)).toBe("11:30 AM–12:30 PM")
    expect(timeRange(ev("c", local(0, 16), 60), false)).toBe("16:00–17:00")
    expect(startTime(ev("d", local(0, 0, 5), 5), true)).toBe("12:05 AM")
  })

  test("12 or 24 hours by region unless set", () => {
    expect(uses12Hour("en-US")).toBe(true)
    expect(uses12Hour("en-GB")).toBe(false)
    expect(uses12Hour("de-DE")).toBe(false)
    expect(uses12Hour("de-DE", "12h")).toBe(true)
    expect(uses12Hour("en-US", "24h")).toBe(false)
  })

  test("the tint is the calendar's color at low alpha; bad colors fall back", () => {
    expect(tintOf("#cc73e1")).toBe("#cc73e12e")
    expect(tintOf("red")).toBe("#1badf82e")
    // A calendar with no color (or an older host) draws in Calendar's default blue.
    expect(tintOf(undefined)).toBe("#1badf82e")
    expect(barOf(undefined)).toBe("#1badf8")
  })

  test("reads again every 5 minutes, not every minute", () => {
    expect(readKey(local(0, 13, 12))).toBe(readKey(local(0, 13, 14)))
    expect(readKey(local(0, 13, 14))).not.toBe(readKey(local(0, 13, 15)))
  })
})
