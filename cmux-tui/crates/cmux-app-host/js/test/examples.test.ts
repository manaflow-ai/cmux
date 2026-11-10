import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "./fake-host.ts"

// The copyable examples (examples/extensions/*): each is a recipe, so its promises are tested here.
const examples = join(import.meta.dir, "../../../../../examples/extensions")
const load = (name: string) => readFileSync(join(examples, name, "dist/main.js"), "utf8")
const ctx = { contribution: "example/clock#cmux.newtab.widget/1", surface: "newTab" }

function clock(settings: Record<string, unknown>) {
  const host = new FakeHost(load("clock"), { app: { id: "example/clock", version: "1.0.0" }, apiVersion: "1.0.0", settings })
  // The VM's clock, so each tick reads a known time (13:41:58 local, then a second later each tick).
  let at = new Date(2026, 10, 10, 13, 41, 58).getTime()
  host.global.Date.now = () => at
  const step = (ms = 1000) => {
    at += ms
  }
  return { host, step }
}

describe("examples", () => {
  test("clock: one Text update per tick with seconds, none until the minute without", async () => {
    const { host, step } = clock({ showSeconds: true, hourCycle: "24h" })
    expect(host.mount("m", "renderClock", ctx)).toBe("")
    await host.settle()
    const texts = () => [...host.tree("m").nodes.values()].map((n) => n.props.text).filter(Boolean)
    expect(texts()).toEqual(["13:41:58", "Tuesday, November 10"])
    // One repeating timer, floored at 1 s by the runtime.
    expect([...host.timers.values()]).toEqual([{ ms: 1000, repeat: true }])
    const [timer] = [...host.timers.keys()]
    const before = host.batches("m").length
    step()
    host.global.__cmuxAppTimer(timer)
    await host.settle()
    const batch = host.lastBatch("m")
    expect(host.batches("m").length).toBe(before + 1)
    expect(batch).toHaveLength(1)
    expect(batch[0]).toMatchObject({ op: "update", props: { text: "13:41:59" } })

    const quiet = clock({ showSeconds: false, hourCycle: "12h" })
    quiet.host.mount("m", "renderClock", ctx)
    await quiet.host.settle()
    expect([...quiet.host.tree("m").nodes.values()].map((n) => n.props.text).filter(Boolean)[0]).toBe("1:41 PM")
    const [quietTimer] = [...quiet.host.timers.keys()]
    const quietBefore = quiet.host.batches("m").length
    quiet.step()
    quiet.host.global.__cmuxAppTimer(quietTimer)
    await quiet.host.settle()
    expect(quiet.host.batches("m").length).toBe(quietBefore)
    quiet.step()
    quiet.host.global.__cmuxAppTimer(quietTimer)
    await quiet.host.settle()
    expect(quiet.host.lastBatch("m")).toEqual([expect.objectContaining({ op: "update", props: { text: "1:42 PM" } })])
  })

  test("clock: unmounting stops the tick", async () => {
    const { host } = clock({})
    host.mount("m", "renderClock", ctx)
    await host.settle()
    expect(host.timers.size).toBe(1)
    host.global.__cmuxAppUnmount("m")
    await host.settle()
    expect(host.timers.size).toBe(0)
  })
})
