// The clock and calendar vocabulary of the scene DSL: host-ticking date Text, fontDesign,
// rotationEffect, offset, position, Line, and the SDK's Timeline built on them.
import { beforeAll, describe, expect, test } from "bun:test"
import * as views from "../src/view.ts"
import { ViewNode } from "../src/view.ts"

type WidgetModule = typeof import("../../../cmux-extension-sdk/typescript/src/widget.ts")
let widget: WidgetModule

beforeAll(async () => {
  // The SDK reads the runtime's view builders from the sandbox's globals, as an extension does.
  Object.assign(globalThis, views, { cmux: {} })
  widget = await import("../../../cmux-extension-sdk/typescript/src/widget.ts")
})

describe("scene DSL: clock vocabulary", () => {
  test("Text({date, style}) is a host-ticking Text: the date and style are props, the text is empty", () => {
    const at = Date.UTC(2026, 10, 16, 17, 41)
    const timer = views.Text({ date: at, style: "timer" })
    expect(timer.props).toEqual({ text: "", date: at, dateStyle: "timer" })
    const world = views.Text({ date: at, timeZone: "Asia/Tokyo" })
    expect(world.props).toEqual({ text: "", date: at, dateStyle: "time", timeZone: "Asia/Tokyo" })
    // A plain Text is unchanged.
    expect(views.Text("9:41").props).toEqual({ text: "9:41" })
  })

  test("fontDesign, rotationEffect, offset and position set their props; Line is a node", () => {
    const time = views.Text("9:41").font(64).weight("heavy").fontDesign("rounded")
    expect(time.props).toMatchObject({ font: 64, weight: "heavy", fontDesign: "rounded" })
    const hand = views.Capsule({ fill: "primary" }).frame({ width: 4, height: 40 }).offset({ y: -20 }).rotationEffect(90)
    expect(hand.props).toMatchObject({ rotation: 90, offset: { y: -20 } })
    const now = views.Line({ stroke: "danger" }).position({ x: 0.5, y: 0.25, unit: "fraction" })
    expect(now.type).toBe("Line")
    expect(now.props).toMatchObject({ stroke: "danger", position: { x: 0.5, y: 0.25, unit: "fraction" } })
  })
})

describe("SDK Timeline", () => {
  test("overlapping events share the width; a later free lane is reused", () => {
    const lanes = widget.timelineLanes([
      { id: "standup", title: "Standup", start: 9, end: 9.5 },
      { id: "review", title: "Design review", start: 9.25, end: 10.5 },
      { id: "lunch", title: "Lunch", start: 12, end: 13 },
      { id: "sync", title: "Sync", start: 9.75, end: 10.25 },
    ])
    expect(lanes.get("standup")).toEqual({ lane: 0, lanes: 2 })
    expect(lanes.get("review")).toEqual({ lane: 1, lanes: 2 })
    // Standup ended at 9:30, so Sync takes its lane.
    expect(lanes.get("sync")).toEqual({ lane: 0, lanes: 2 })
    expect(lanes.get("lunch")).toEqual({ lane: 0, lanes: 1 })
  })

  test("an hour grid in a ZStack, each event placed at its time and the now line at now", () => {
    const events = [
      { id: "a", title: "Standup", start: 9, end: 10 },
      { id: "b", title: "Review", start: 9.5, end: 11 },
    ]
    const now = new Date(2026, 10, 16, 10, 30).getTime()
    const view = widget.Timeline({ startHour: 8, endHour: 12, events: () => events, now: () => now, width: 334, hourHeight: 30 })
    expect(view.type).toBe("ZStack")
    const [grid, list, line, dot] = view.children as ViewNode[]
    expect(grid!.type).toBe("VStack")
    expect(grid!.children.length).toBe(5)
    expect(list!.type).toBe("ForEach")
    const item = (event: (typeof events)[number]) => list!.list!.template(() => event, event.id)
    const standup = item(events[0]!)
    const review = item(events[1]!)
    const place = (node: ViewNode) => (node.props.position as () => { x: number; y: number })()
    // Grid width 300 after the 34 pt labels, two lanes of 150; 9:00 is 30 pt below 8:00.
    expect(place(standup)).toEqual({ x: 34 + 75, y: 30 + 14 })
    expect(place(review).x).toBe(34 + 225)
    expect(line!.type).toBe("Line")
    expect(place(line!)).toEqual({ x: 34 + 150, y: 75 })
    expect(dot!.type).toBe("Circle")
  })
})
