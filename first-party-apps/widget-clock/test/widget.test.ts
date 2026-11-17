// Runs the packed widget the way cmux does (the shipped app runtime in a fresh VM context) and
// reads the scene it draws, for each size and face.
process.env.TZ = "America/Los_Angeles"
import { describe, expect, test } from "bun:test"
import { join } from "node:path"
import { FakeHost, pack } from "cmux-extension-sdk/testing"
import { renderScene, AT } from "../preview/scenes.ts"

const source = await pack(join(import.meta.dir, ".."))

const texts = (ops: { type?: string; props?: Record<string, unknown> }[]) =>
  ops.filter((op) => op.type === "Text").map((op) => String(op.props?.text ?? ""))

describe("clock widget", () => {
  test("small: the weekday, the date and the big time, with zero setup", async () => {
    const { ops, host } = await renderScene(source, { size: "small" })
    expect(texts(ops)).toEqual(["MONDAY", "Nov 16", "9:41", "AM"])
    const time = ops.find((op) => op.props?.text === "9:41")!
    expect(time.props).toMatchObject({ font: 50, weight: "heavy" })
    expect(host.logs.filter(([level]) => level === "error")).toEqual([])
  })

  test("medium adds two cities, large four, each with its distance and day", async () => {
    const medium = texts((await renderScene(source, { size: "medium" })).ops)
    expect(medium).toContain("New York")
    expect(medium).toContain("London")
    expect(medium).not.toContain("Tokyo")
    const large = texts((await renderScene(source, { size: "large" })).ops)
    expect(large[0]).toBe("Monday, November 16")
    for (const name of ["New York", "London", "Tokyo", "Sydney"]) expect(large).toContain(name)
    expect(large).toContain("Tomorrow, +17h")
  })

  test("24 hours and your own cities", async () => {
    const ops = (await renderScene(source, { size: "large", settings: { hourCycle: "24h", cities: "Europe/Paris, Asia/Kolkata" } })).ops
    const shown = texts(ops)
    expect(shown).toContain("09:41")
    expect(shown).not.toContain("AM")
    expect(shown).toEqual(expect.arrayContaining(["Paris", "Kolkata", "18:41", "23:11"]))
  })

  test("analog: a dial with its hands at the time", async () => {
    const { ops } = await renderScene(source, { size: "small", settings: { face: "analog" } })
    const rotations = ops.filter((op) => typeof op.props?.rotation === "number").map((op) => (op.props!.rotation as number) % 360)
    // 9:41: the hour hand at 290.5 degrees, the minute hand at 246.
    expect(rotations).toContain(290.5)
    expect(rotations).toContain(246)
    expect(texts(ops)).toEqual(["MON 16"])
  })

  test("with the widget host's clock: no timer of its own, and a tick redraws only the time", async () => {
    const { host } = await renderScene(source, { size: "small" })
    expect(host.timers.size).toBe(0)
    const before = host.batches("w").length
    host.global.__cmuxAppTick("w", AT + 60_000)
    await host.settle()
    expect(host.batches("w").slice(before).flat()).toEqual([{ op: "update", id: expect.any(String), props: { text: "9:42" } }])
  })

  test("as a place without the host's clock (an older cmux): one one-shot timer to the next minute, and a tick redraws only the time", async () => {
    const { host } = await renderScene(source, { size: "small", surface: "section" })
    const timers = [...host.timers.entries()]
    expect(timers.map(([, t]) => t.repeat)).toEqual([false])
    const [[id, { ms }]] = timers as [[number, { ms: number }]]
    expect(ms).toBe(60_000 - 12_000 + 25)
    const before = host.batches("w").length
    host.eval(`Date.now = () => ${AT + ms}`)
    host.global.__cmuxAppTimer(id)
    await host.settle()
    const tick = host.batches("w").slice(before).flat()
    expect(tick.every((op) => op.op === "update")).toBe(true)
    expect(tick.map((op) => op.props?.text)).toEqual(["9:42"])
    // The fired one-shot armed the next (the fake host keeps fired timers in its list).
    expect([...host.timers.values()].at(-1)).toEqual({ ms: 60_000, repeat: false })
  })

  test("the time's weight and color settings, and the date turned off", async () => {
    const { ops } = await renderScene(source, { size: "small", settings: { font: "mono", weight: "thin", color: "#FF9500", date: false } })
    expect(texts(ops)).toEqual(["9:41", "AM"])
    const time = ops.find((op) => op.props?.text === "9:41")!
    expect(time.props).toMatchObject({ weight: "thin", color: "#FF9500", opacity: 1 })
    // mono: the scene's font design where the host has it, else monospaced.
    expect(time.props?.fontDesign === "monospaced" || time.props?.monospaced === true).toBe(true)
    const glass = (await renderScene(source, { size: "large", settings: { color: "glass" } })).ops.find((op) => op.props?.text === "9:41")!
    expect(glass.props).toMatchObject({ color: "primary", opacity: 0.55, weight: "heavy" })
  })

  test("the person's zone from the context: its time and day, its name on the analog row, and no city at its own offset", async () => {
    const small = (await renderScene(source, { size: "small", timeZone: "Asia/Tokyo" })).ops
    expect(texts(small)).toEqual(["TUESDAY", "Nov 17", "2:41", "AM"])
    expect(small.find((op) => op.props?.text === "TUESDAY")!.props).toMatchObject({ color: "#FF3B30" })
    const row = texts((await renderScene(source, { size: "medium", timeZone: "Asia/Tokyo", settings: { face: "analog" } })).ops)
    expect(row[0]).toBe("Tokyo")
    expect(row).not.toContain("Here")
    expect(row).toContain("Los Angeles")
    const large = texts((await renderScene(source, { size: "large", timeZone: "Asia/Tokyo" })).ops)
    expect(large).toContain("Yesterday, \u221217h")
    // An unknown zone name: the runtime's clock, and "Here".
    expect(texts((await renderScene(source, { size: "medium", timeZone: "Nowhere/City", settings: { face: "analog" } })).ops)[0]).toBe("Here")
  })
})
