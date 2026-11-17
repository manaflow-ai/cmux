// Runs the packed widget the way cmux does (the shipped app runtime in a fresh VM context) against
// a fake calendar, and reads the scene it draws for each size and day.
process.env.TZ = "America/Los_Angeles"
import { describe, expect, test } from "bun:test"
import { join } from "node:path"
import { pack } from "cmux-extension-sdk/testing"
import { renderScene, visible, AT } from "../preview/scenes.ts"

const source = await pack(join(import.meta.dir, ".."))

type SceneOp = { type?: string; props?: Record<string, unknown> }
const texts = (ops: SceneOp[]) => visible(ops as never).filter((op) => op.type === "Text").map((op) => String(op.props?.text ?? ""))
const buttons = (ops: SceneOp[]) => visible(ops as never).filter((op) => op.type === "Button")

describe("calendar widget", () => {
  test("small: the weekday in red, the day, then the next two events", async () => {
    const { ops, host, calls } = await renderScene(source, { size: "small", day: "busy" })
    const shown = texts(ops)
    expect(shown.slice(0, 2)).toEqual(["TUESDAY", "17"])
    expect(ops.find((op) => op.props?.text === "TUESDAY")!.props).toMatchObject({ color: "#ff3b30" })
    // The 1:30 review is next (the 9:30 standup ended); two events share the tile as title and start.
    expect(shown).toEqual(["TUESDAY", "17", "Design review", "1:30 PM", "Yoga Class", "4:00 PM"])
    expect(calls).toEqual([["system_calendar.events", { days: 2, limit: 50 }]])
    expect(host.logs.filter(([level]) => level === "error")).toEqual([])
  })

  test("each event carries its calendar's color as a bar and a tint", async () => {
    const { ops } = await renderScene(source, { size: "medium", day: "busy" })
    const backgrounds = visible(ops).map((op) => op.props?.background).filter(Boolean)
    expect(backgrounds).toContain("#1badf82e")
    expect(backgrounds).toContain("#1badf8")
    expect(backgrounds).toContain("#cc73e12e")
  })

  test("medium: next event on the left, the rest of today then tomorrow on the right", async () => {
    const shown = texts((await renderScene(source, { size: "medium", day: "busy" })).ops)
    expect(shown).toEqual([
      "TUESDAY", "17",
      "Design review", "Room 4", "1:30–2:30 PM",
      "Yoga Class", "Golden Gate Park", "4:00–5:00 PM",
      "Dinner with Ravi", "Nopa", "6:00–7:30 PM"
    ])
    const clear = texts((await renderScene(source, { size: "medium", day: "clear" })).ops)
    expect(clear).toEqual(["TUESDAY", "17", "No more events today", "TOMORROW", "Pick up coffee", "Coffee Shop", "8:30–9:00 AM", "1:1 with Aziz", "Zoom", "11:00–11:30 AM"])
  })

  test("large: Apple's hour grid, today from the current hour with the now line, tomorrow from before its first event", async () => {
    const { ops } = await renderScene(source, { size: "large", day: "busy" })
    const shown = texts(ops)
    // Today: 1 PM (now is 1:12) for 5 hours; the 1:30 review, 4:00 yoga and 6:00 dinner on it.
    expect(shown.slice(0, 8)).toEqual(["TUESDAY", "17", "1", "2", "3", "4", "5", "6"])
    for (const t of ["Design review", "Yoga Class", "Dinner with Ravi"]) expect(shown).toContain(t)
    // 8:30 PM is past the grid's end; the 9:30 AM standup has ended.
    expect(shown).not.toContain("Call Mom")
    expect(shown).not.toContain("Team standup")
    // Tomorrow: from 7 (an hour before the 8:30 coffee), seven hours.
    const tomorrow = shown.slice(shown.indexOf("TOMORROW") + 1)
    expect(tomorrow.slice(0, 8)).toEqual(["7", "8", "9", "10", "11", "12", "1", "2"])
    for (const t of ["Pick up coffee", "1:1 with Aziz"]) expect(tomorrow).toContain(t)
    // The red now line: a dot and a line in Calendar's red, offset to 1:12 (12 of 36 points into the hour).
    const red = visible(ops as never).filter((op) => op.props?.fill === "#ff3b30" || op.props?.stroke === "#ff3b30")
    expect(red.map((op) => op.type)).toEqual(["Circle", "Line"])
    // Blocks keep the calendar's tint.
    const backgrounds = visible(ops as never).map((op) => op.props?.background)
    expect(backgrounds).toContain("#cc73e12e")
  })

  test("large as a list (the setting): the rest of today, then tomorrow with its own column", async () => {
    const shown = texts((await renderScene(source, { size: "large", day: "busy", settings: { largeLayout: "list" } })).ops)
    expect(shown.indexOf("TOMORROW")).toBeGreaterThan(shown.indexOf("Call Mom"))
    for (const t of ["Design review", "Yoga Class", "Dinner with Ravi", "Call Mom", "Pick up coffee", "1:1 with Aziz", "Dentist"]) expect(shown).toContain(t)
    expect(shown).not.toContain("Team standup")
  })

  test("the time zone is the person's, not the process's", async () => {
    // The same instant in Tokyo is Wednesday 6:12 AM: the 4 PM LA yoga is 9 AM Wednesday there.
    const shown = texts((await renderScene(source, { size: "medium", day: "busy", timeZone: "Asia/Tokyo" })).ops)
    expect(shown.slice(0, 2)).toEqual(["WEDNESDAY", "18"])
    expect(shown).toContain("9:00–10:00 AM")
  })

  test("a clear day says so, as Apple's widget does", async () => {
    expect(texts((await renderScene(source, { size: "small", day: "clear" })).ops)).toEqual(["TUESDAY", "17", "No more events today"])
    const empty = texts((await renderScene(source, { size: "large", day: "empty", settings: { largeLayout: "list" } })).ops)
    expect(empty).toEqual(["TUESDAY", "17", "No more events today", "TOMORROW", "No events"])
    const grid = texts((await renderScene(source, { size: "large", day: "empty" })).ops)
    expect(grid).toContain("No more events today")
    expect(grid).toContain("No events")
  })

  test("all-day events come first, title only", async () => {
    const shown = texts((await renderScene(source, { size: "medium", day: "allDay" })).ops)
    expect(shown.slice(0, 3)).toEqual(["TUESDAY", "17", "Maya's Birthday"])
    expect(shown).toContain("Yoga Class")
  })

  test("first install: one button asks for access, then the events show", async () => {
    const { ops, host } = await renderScene(source, { size: "small", day: "ask" })
    expect(texts(ops)).toEqual(["TUESDAY", "17", "See your next events here."])
    const allow = buttons(ops)
    expect(allow.map((b) => b.props?.title ?? b.props?.label)).toEqual(["Allow Access"])
    // The person taps it: the prompt op runs with their gesture, then the widget reads again.
    host.handlers["system_calendar.events"] = () => ({ ok: true, body: { value: { access: "granted", events: [] } } })
    host.dispatch("w", (allow[0] as { id: string }).id, "tap", { gesture: "gesture-1" })
    await host.settle()
    const asked = host.calls.filter((c) => c.name === "system_calendar.request_access")
    expect(asked.map((c) => c.options?.gesture)).toEqual(["gesture-1"])
    expect(host.calls.filter((c) => c.name === "system_calendar.events").length).toBe(2)
    expect(texts(host.batches("w").flat())).toEqual(["TUESDAY", "17", "No more events today"])
  })

  test("denied: it says where to turn access on, with no button; 24 hours when set", async () => {
    const denied = await renderScene(source, { size: "medium", day: "denied" })
    expect(texts(denied.ops)).toContain("Calendar access is off. Turn it on for cmux in System Settings > Privacy & Security > Calendars.")
    expect(buttons(denied.ops)).toEqual([])
    const h24 = texts((await renderScene(source, { size: "large", day: "busy", settings: { hourCycle: "24h", largeLayout: "list" } })).ops)
    expect(h24).toContain("13:30–14:30")
  })

  test("off the Mac (no calendar provider) it says where it works", async () => {
    const shown = texts((await renderScene(source, { size: "small", day: "offMac" })).ops)
    expect(shown).toEqual(["TUESDAY", "17", "Your calendar shows here in the cmux app on a Mac."])
    expect(AT).toBeGreaterThan(0)
  })
})
