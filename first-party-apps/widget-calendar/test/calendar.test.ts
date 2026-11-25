process.env.TZ = "America/Los_Angeles"
import { describe, expect, test } from "bun:test"
import { agenda, barOf, READ, startOfNextDay, timeRange, startTime, tintOf, uses12Hour, weekdayHeading, dayNumber, fixedOffset, gridColumn, hourLabel, startOfDay, type CalendarEvent } from "../src/calendar.ts"

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

})

describe("the person's zone, not the process's", () => {
  const LA = fixedOffset(-480)
  const TOKYO = fixedOffset(540)
  // 1:12 PM in Los Angeles is 6:12 AM Wednesday in Tokyo.
  const AT = Date.UTC(2026, 10, 17, 21, 12)

  test("the day, its midnight and the clock follow the given zone", () => {
    expect(weekdayHeading(AT, LA)).toBe("TUESDAY")
    expect(weekdayHeading(AT, TOKYO)).toBe("WEDNESDAY")
    expect(dayNumber(AT, TOKYO)).toBe("18")
    expect(startOfDay(AT, TOKYO)).toBe(Date.UTC(2026, 10, 17, 15))
    expect(startTime({ start: AT }, true, TOKYO)).toBe("6:12 AM")
    expect(startTime({ start: AT }, false, LA)).toBe("13:12")
  })

  test("a DST change: midnight is found from the offset at that midnight", () => {
    // Los Angeles, Sunday November 1 2026: PDT (-420) until 2 AM, PST (-480) after.
    const la = (at: number) => (at < Date.UTC(2026, 10, 1, 9) ? -420 : -480)
    const sunday = Date.UTC(2026, 10, 1, 17) // 9 AM PST
    expect(startOfDay(sunday, la)).toBe(Date.UTC(2026, 10, 1, 7))
    expect(startOfNextDay(sunday, la)).toBe(Date.UTC(2026, 10, 2, 8))
  })
})

describe("the large hour grid", () => {
  const LA = fixedOffset(-480)
  const day0 = Date.UTC(2026, 10, 17, 8) // midnight Tuesday in LA
  const day1 = Date.UTC(2026, 10, 18, 8)
  const at = (day: number, h: number, m = 0) => day + (h * 60 + m) * 60_000
  const e = (id: string, start: number, minutes: number): CalendarEvent => ({ id, title: id, start, end: start + minutes * 60_000, allDay: false, calendar: "Home" })

  test("today starts at the current hour with the now line in it, as Apple's 1 with the line at 1:12", () => {
    const col = gridColumn([e("yoga", at(day0, 16), 60)], day0, 6, LA, at(day0, 13, 12))
    expect([col.startHour, col.endHour]).toEqual([13, 19])
    expect(col.now).toBeCloseTo(13.2)
    expect(col.blocks.map((b) => [b.e.id, b.from, b.to])).toEqual([["yoga", 16, 17]])
  })

  test("tomorrow starts an hour before its first event; overlaps share the width; late events stay in the day", () => {
    const col = gridColumn([e("coffee", at(day1, 8, 30), 30), e("a", at(day1, 10), 60), e("b", at(day1, 10, 30), 60)], day1, 7, LA)
    expect([col.startHour, col.endHour]).toEqual([7, 14])
    expect(col.now).toBeUndefined()
    expect(col.blocks.map((b) => [b.e.id, b.lane, b.lanes])).toEqual([["coffee", 0, 1], ["a", 0, 2], ["b", 1, 2]])
    expect(gridColumn([e("late", at(day1, 22), 60)], day1, 7, LA).startHour).toBe(17)
  })

  test("hour labels as Apple writes them", () => {
    expect([12, 13, 0, 23].map((h) => hourLabel(h, true))).toEqual(["12", "1", "12", "11"])
    expect([12, 13, 0].map((h) => hourLabel(h, false))).toEqual(["12", "13", "0"])
  })
})
