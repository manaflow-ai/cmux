process.env.TZ = "America/Los_Angeles"
import { describe, expect, test } from "bun:test"
import { cities, city, dateLine, handAngles, localeIsTwelveHour, showsDate, timeParts, timeStyle, twelveHour, untilNextMinute, wall, zonesFrom, type ZoneOf } from "../src/clock.ts"

// Monday, November 16, 2026, 9:41 AM in Los Angeles (PST, UTC-8).
const AT = Date.UTC(2026, 10, 16, 17, 41, 12)
const OFFSETS: Record<string, number> = {
  "America/Los_Angeles": -480,
  "America/New_York": -300,
  "Europe/London": 0,
  "Asia/Tokyo": 540,
  "Australia/Sydney": 660,
  "Asia/Kolkata": 330
}
const zoneOf: ZoneOf = (zone) => {
  if (!(zone in OFFSETS)) throw { code: "zone.unknown" }
  return { offsetMinutes: OFFSETS[zone]!, abbreviation: "" }
}

describe("time and date", () => {
  test("12 and 24 hour times", () => {
    const here = wall(AT, -480)
    expect(timeParts(here, true)).toEqual({ time: "9:41", period: "AM" })
    expect(timeParts(here, false)).toEqual({ time: "09:41", period: "" })
    expect(timeParts(wall(Date.UTC(2026, 10, 16, 8, 5), 0), true)).toEqual({ time: "8:05", period: "AM" })
    expect(timeParts(wall(Date.UTC(2026, 10, 16, 0, 5), 0), true)).toEqual({ time: "12:05", period: "AM" })
    expect(timeParts(wall(Date.UTC(2026, 10, 16, 12, 0), 0), true)).toEqual({ time: "12:00", period: "PM" })
  })

  test("the Lock Screen date line", () => {
    expect(dateLine(wall(AT, -480))).toBe("Monday, November 16")
  })

  test("the hour cycle follows the setting, else the locale", () => {
    expect(twelveHour({ hourCycle: "24h" }, "en-US")).toBe(false)
    expect(twelveHour({ hourCycle: "12h" }, "de-DE")).toBe(true)
    expect(twelveHour({}, "en-US")).toBe(true)
    expect(twelveHour({ hourCycle: "system" }, "en-GB")).toBe(false)
    expect(twelveHour({}, "fr-FR")).toBe(false)
  })

  test("without Intl the locale's region decides", () => {
    const intl = globalThis.Intl
    try {
      // @ts-expect-error the sandbox has no Intl
      delete globalThis.Intl
      expect(localeIsTwelveHour("en-US")).toBe(true)
      expect(localeIsTwelveHour("en_AU")).toBe(true)
      expect(localeIsTwelveHour("en-GB")).toBe(false)
      expect(localeIsTwelveHour("ja-JP")).toBe(false)
      expect(localeIsTwelveHour("en")).toBe(true)
      expect(localeIsTwelveHour("de")).toBe(false)
    } finally {
      globalThis.Intl = intl
    }
  })

  const turn = (a: { hourAngle: number; minuteAngle: number }) => ({ hourAngle: a.hourAngle % 360, minuteAngle: a.minuteAngle % 360 })
  test("analog hands", () => {
    expect(turn(handAngles(wall(Date.UTC(2026, 0, 1, 3, 0), 0)))).toEqual({ hourAngle: 90, minuteAngle: 0 })
    expect(turn(handAngles(wall(Date.UTC(2026, 0, 1, 21, 30), 0)))).toEqual({ hourAngle: 285, minuteAngle: 180 })
    // They only grow, so the host animates :59 to :00 forward.
    const before = handAngles(wall(Date.UTC(2026, 0, 1, 11, 59), 0))
    const after = handAngles(wall(Date.UTC(2026, 0, 1, 12, 0), 0))
    expect(after.minuteAngle - before.minuteAngle).toBe(6)
    expect(after.hourAngle - before.hourAngle).toBe(0.5)
  })

  test("the next tick lands just after the minute starts", () => {
    const wait = untilNextMinute(AT)
    expect(new Date(AT + wait).getUTCSeconds()).toBe(0)
    expect(wait).toBeLessThanOrEqual(60_025)
  })
})

describe("cities", () => {
  test("a city knows its time, its distance from you and its day", () => {
    expect(city("Asia/Tokyo", AT, true, zoneOf)).toMatchObject({ name: "Tokyo", time: "2:41", period: "AM", offset: "+17h", day: "Tomorrow" })
    expect(city("America/New_York", AT, false, zoneOf)).toMatchObject({ name: "New York", time: "12:41", offset: "+3h", day: "Today" })
    expect(city("Asia/Kolkata", AT, false, zoneOf)).toMatchObject({ offset: "+13:30h" })
  })

  test("an unknown zone shows itself as one, without breaking the rest", () => {
    expect(city("Mars/Olympus_Mons", AT, true, zoneOf)).toMatchObject({ name: "Olympus Mons", problem: true, day: "Unknown zone" })
  })

  test("zero setup: the defaults skip your own time", () => {
    const shown = cities("", AT, true, zoneOf, 4).map((c) => c.name)
    expect(shown).toEqual(["New York", "London", "Tokyo", "Sydney"])
  })

  test("a list you wrote is shown as written, without repeats", () => {
    expect(zonesFrom("Asia/Tokyo, Europe/London,\nAsia/Tokyo")).toEqual(["Asia/Tokyo", "Europe/London"])
    expect(cities("America/Los_Angeles, Asia/Tokyo", AT, true, zoneOf, 4).map((c) => c.name)).toEqual(["Los Angeles", "Tokyo"])
  })
})

describe("the time's look (the New Tab clock's options, cmux#44388)", () => {
  test("zero setup: rounded, heavy, the theme's text, with the date", () => {
    expect(timeStyle({})).toEqual({ font: "rounded", design: "rounded", weight: "heavy", color: "primary", opacity: 1 })
    expect(showsDate({})).toBe(true)
    expect(showsDate({ date: false })).toBe(false)
  })

  test("every font, weight and color choice", () => {
    expect(["rounded", "system", "serif", "mono", "condensed"].map((font) => timeStyle({ font: font as never }).design)).toEqual(["rounded", "default", "serif", "monospaced", "default"])
    expect(timeStyle({ weight: "thin" }).weight).toBe("thin")
    expect(timeStyle({ color: "accent" }).color).toBe("accent")
    expect(timeStyle({ color: "muted" }).color).toBe("secondary")
    expect(timeStyle({ color: "glass" })).toMatchObject({ color: "primary", opacity: 0.55 })
    expect(timeStyle({ color: " #ff9500 " })).toMatchObject({ color: "#FF9500", opacity: 1 })
  })

  test("a value that is no choice reads as the default", () => {
    expect(timeStyle({ font: "comic" as never, weight: "x" as never, color: "red" })).toMatchObject({ font: "rounded", weight: "heavy", color: "primary" })
    expect(timeStyle({ color: "#fff" }).color).toBe("primary")
  })
})
