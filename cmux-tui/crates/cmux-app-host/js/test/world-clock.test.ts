// local/showcase-world-clock (examples/extensions/world-clock) in the fake host, packed from
// src/main.ts. Its zone rules come from cmux.time.zone (the fake host answers from Intl, as the
// native one does from its zone database).
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const dir = join(import.meta.dir, "../../../../../examples/extensions/world-clock")
let built = ""
beforeAll(async () => {
  built = await pack(dir)
})

// 2026-07-01 23:30 UTC: Tokyo is already on July 2nd, Los Angeles still on July 1st.
const AT = Date.UTC(2026, 6, 1, 23, 30)

function host(settings: Record<string, unknown> = {}) {
  const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
  const h = new FakeHost(built, { app: { id: manifest.id, version: "1.0.0" }, settings, apiVersion: "1.0.0" })
  // The clock reads the time the test sets, in UTC (local offset 0).
  h.eval(`Date.now = () => globalThis.__now; Date.prototype.getTimezoneOffset = () => 0; globalThis.__now = ${AT}`)
  return h
}

function rows(h: FakeHost, mount: string) {
  const tree = h.tree(mount)
  const out: Array<Record<string, unknown>> = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    if (n.type === "Row") out.push(n.props)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out.map((r) => ({ title: r.title, subtitle: r.subtitle, accessory: r.accessory }))
}

describe("local/showcase-world-clock", () => {
  test("imports nothing but the SDK", () => {
    const src = readFileSync(join(dir, "src/main.ts"), "utf8")
    expect([...src.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1])).toEqual(["cmux-extension-sdk"])
    expect(built).toContain("function renderWorldClock(")
  })

  test("each zone's wall time, its distance from you, and its day when it is not yours", () => {
    const h = host({ zones: "America/Los_Angeles, Asia/Tokyo, Asia/Kolkata, UTC" })
    h.mount("m", "renderWorldClock")
    expect(rows(h, "m")).toEqual([
      { title: "Los Angeles", subtitle: "−7 h · PDT", accessory: "16:30" },
      { title: "Tokyo", subtitle: "Tomorrow · +9 h · GMT+9", accessory: "08:30" },
      { title: "Kolkata", subtitle: "Tomorrow · +5:30 h · GMT+5:30", accessory: "05:00" },
      { title: "UTC", subtitle: "Same time as you · UTC", accessory: "23:30" }
    ])
  })

  test("a 12-hour clock, the default zones, and a name that is no zone", () => {
    const h = host({ hour12: true })
    h.mount("m", "renderWorldClock")
    expect(rows(h, "m").map((r) => [r.title, r.accessory])).toEqual([
      ["Los Angeles", "4:30 PM"],
      ["New York", "7:30 PM"],
      ["London", "12:30 AM"],
      ["Tokyo", "8:30 AM"]
    ])
    const bad = host({ zones: "Mars/Olympus" })
    bad.mount("m", "renderWorldClock")
    const [row] = rows(bad, "m")
    expect(row!.accessory).toBeNull()
    expect(String(row!.subtitle)).toStartWith("Not a time zone")
  })

  test("ticks just after each minute, and its pending timer ends with the view", () => {
    const h = host({ zones: "UTC" })
    h.mount("m", "renderWorldClock")
    expect([...h.timers.values()]).toEqual([{ ms: 60_050, repeat: false }])
    const [id] = [...h.timers.keys()]
    h.timers.delete(id!)
    h.eval(`globalThis.__now = ${AT + 60_050}`)
    h.global.__cmuxAppTimer(id)
    expect(rows(h, "m")[0]!.accessory).toBe("23:31")
    expect([...h.timers.values()]).toEqual([{ ms: 60_000, repeat: false }])
    h.global.__cmuxAppUnmount("m")
    expect(h.timers.size).toBe(0)
  })
})
