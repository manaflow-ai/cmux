// local/leo-clock (examples/extensions/leo-clock) in the fake host, packed from src/main.ts: the
// New Tab clock declares its motion (the renderer runs it) and the world clock section's rows.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const dir = join(import.meta.dir, "../../../../../examples/extensions/leo-clock")
let built = ""
beforeAll(async () => {
  built = await pack(dir)
})

// 2026-07-01 23:59:58 UTC, read as local time (offset 0).
const AT = Date.UTC(2026, 6, 1, 23, 59, 58)

function host(settings: Record<string, unknown> = {}) {
  const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
  const h = new FakeHost(built, { app: { id: manifest.id, version: "1.0.0" }, settings, apiVersion: "1.0.0" })
  h.eval(`Date.now = () => globalThis.__now; Date.prototype.getTimezoneOffset = () => 0; globalThis.__now = ${AT}`)
  return h
}

function nodes(h: FakeHost, mount: string) {
  const tree = h.tree(mount)
  const out: Array<{ type: string; props: Record<string, unknown> }> = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    out.push(n)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

/** Advance the clock to `at` and fire the pending one-shot tick. */
function tick(h: FakeHost, at: number) {
  const [id] = [...h.timers.keys()]
  h.timers.delete(id!)
  h.eval(`globalThis.__now = ${at}`)
  h.global.__cmuxAppTimer(id)
}

const sweeping = (h: FakeHost, m: string) =>
  nodes(h, m).filter((n) => typeof n.props.rotation === "number" && (n.props.animation as { curve?: string } | undefined)?.curve === "linear")
const texts = (h: FakeHost, m: string) => nodes(h, m).filter((n) => n.type === "Text").map((n) => n.props.text)

describe("local/leo-clock", () => {
  test("imports nothing but the SDK and defines both exports", () => {
    const src = readFileSync(join(dir, "src/main.ts"), "utf8") + readFileSync(join(dir, "src/time.ts"), "utf8")
    expect(new Set([...src.matchAll(/from\s+"([^"]+)"/g)].map((m) => m[1]))).toEqual(new Set(["cmux-extension-sdk", "./time.ts"]))
    expect(built).toContain("renderNewTab")
    expect(built).toContain("renderWorldClock")
  })

  test("analog: the hands sweep on a 1 s linear animation, and the second hand never runs backwards past midnight", () => {
    const h = host({ name: "Leo" })
    h.mount("m", "renderNewTab", { surface: "newTab" })
    expect(texts(h, "m")).toContain("Good evening, Leo")
    const before = sweeping(h, "m").map((n) => n.props.rotation as number)
    expect(before).toHaveLength(3)
    tick(h, AT + 2000) // 00:00:00 the next day
    const after = sweeping(h, "m").map((n) => n.props.rotation as number)
    for (let i = 0; i < 3; i++) expect(after[i]!).toBeGreaterThan(before[i]!)
    expect(after[2]! - before[2]!).toBe(12)
    expect(texts(h, "m")).toContain("Up late, Leo")
  })

  test("a digit that changes is a new keyed node with a slide transition; the colon breathes", () => {
    const h = host({ variant: "flip" })
    h.mount("m", "renderNewTab", { surface: "newTab" })
    const slid = () => nodes(h, "m").filter((n) => n.type === "Text" && n.props.transition === "slide").map((n) => n.props.text)
    expect(slid()).toEqual(["2", "3", "5", "9", "5", "8"])
    tick(h, AT + 1000)
    expect(slid()).toEqual(["2", "3", "5", "9", "5", "9"])
    expect(nodes(h, "m").some((n) => n.props.text === ":" && (n.props.loop as { effect?: string })?.effect === "breathe")).toBe(true)
  })

  test("ring: a day ring per zone, trimmed to how far through its day it is", () => {
    const h = host({ variant: "ring", zones: "UTC, Asia/Tokyo" })
    h.mount("m", "renderNewTab", { surface: "newTab" })
    const trims = nodes(h, "m").filter((n) => n.props.trim).map((n) => (n.props.trim as { to: number }).to)
    expect(trims).toHaveLength(3)
    expect(trims[2]!).toBeCloseTo((8 * 3600 + 59 * 60 + 58) / 86_400, 5)
    expect(texts(h, "m")).toContain("Tokyo")
  })

  test("the world clock section: a row per zone, once a minute, and its timer ends with the view", () => {
    const h = host({ zones: "America/Los_Angeles, Asia/Tokyo", hour12: true })
    h.mount("s", "renderWorldClock")
    const rows = nodes(h, "s").filter((n) => n.type === "Row").map((n) => [n.props.title, n.props.accessory, n.props.subtitle])
    expect(rows).toEqual([
      ["Los Angeles", "4:59 PM", "−7 h · PDT"],
      ["Tokyo", "8:59 AM", "+9 h · GMT+9"],
    ])
    expect([...h.timers.values()][0]!.ms).toBe(2020)
    h.global.__cmuxAppUnmount("s")
    expect(h.timers.size).toBe(0)
  })
})
