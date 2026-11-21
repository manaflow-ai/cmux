// The collection setup (examples/customize-showcase/collection): its view script runs as
// written, with only the ops its manifest's scopes grant.
import { readFileSync } from "node:fs"
import { describe, expect, test } from "bun:test"
import { FakeHost } from "./fake-host.ts"

const folder = new URL("../../../../../examples/customize-showcase/collection/customize/", import.meta.url)
const source = readFileSync(new URL("main.js", folder), "utf8")

function init() {
  const scopes = Object.keys(JSON.parse(readFileSync(new URL("cmux-app.json", folder), "utf8")).scopes ?? {})
  const table: Record<string, { scope: string }> = JSON.parse(readFileSync(new URL("../../generated/scopes.json", import.meta.url), "utf8")).ops
  const granted = (scope: string) => scope === "none" || scopes.includes(scope) || (scope === "net:<host>" && scopes.some((s) => s.startsWith("net:")))
  const ops = Object.entries(table).filter(([, v]) => granted(v.scope)).map(([op]) => op)
  return { app: { id: "local/customize", version: "1.0.0" }, apiVersion: "1.0.0", ops }
}

const ok = (value: unknown = null) => () => ({ ok: true, body: { value } })
const STATUS = {
  state: "ready",
  providers: [
    {
      id: "claude",
      summary: { usable: 2, total: 3, weekly_left_sum_pct: 150 },
      pace: { verdict: "onPace" },
      accounts: [
        { weekly_left_pct: 80, session_left_pct: 40, extra_usage_usd: 1.5 },
        { weekly_left_pct: 64, session_left_pct: 90, extra_usage_usd: null },
        { weekly_left_pct: null, session_left_pct: null, extra_usage_usd: null }
      ]
    }
  ]
}

function host(saved: Record<string, unknown> = {}) {
  const h = new FakeHost(source, init())
  h.handlers["app.storage.get"] = (p) => ({ ok: true, body: { value: saved[p.key] ?? null } })
  h.handlers["app.storage.set"] = ok()
  h.handlers["usage_app.status"] = ok(STATUS)
  h.handlers["toast.show"] = ok()
  return h
}

/** Fires the one-shot timers (animation frames) until none is armed; returns how many fired. */
async function runFrames(h: FakeHost, each?: () => void) {
  let fired = 0
  for (let guard = 0; guard < 500; guard++) {
    const due = [...h.timers].filter(([, t]) => !t.repeat)
    if (!due.length) return fired
    for (const [id] of due) {
      h.timers.delete(id)
      h.global.__cmuxAppTimer(id)
      fired += 1
    }
    await h.settle()
    each?.()
  }
  throw new Error("frames never stopped")
}

function texts(h: FakeHost): string[] {
  const tree = h.tree("m")
  const out: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    if (n.type === "Text") out.push(String(n.props.text))
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

describe("the collection", () => {
  test("draws the time, reads usage with its own scope and counts the meter up to the mean weekly left", async () => {
    const h = host()
    expect(h.mount("m", "renderSection")).toBe("")
    await h.settle(10)
    expect(h.calls.find((c) => c.name === "usage_app.status")?.params).toEqual({ accounts: true, refresh: false })
    expect(await runFrames(h)).toBeGreaterThan(5)
    const t = texts(h)
    expect(t.some((x) => /^\d\d:\d\d$/.test(x))).toBe(true)
    expect(t).toContain("Claude")
    expect(t).toContain("72%")
    expect(t).toContain("left this week · session 40% · on pace · $1.50 extra")
    // A clock, a usage read every 5 minutes and the weather every 15; nothing repeats faster.
    expect([...h.timers.values()].map((x) => x.ms).sort((a, b) => a - b)).toEqual([15000, 300000, 900000])
  })

  test("with no Usage app the card says why instead of a spinner", async () => {
    const h = host()
    delete h.handlers["usage_app.status"]
    h.mount("m", "renderSection")
    await h.settle(10)
    expect(h.findNode("m", (n) => n.type === "EmptyState" && n.props.title === "No usage yet")).toBeDefined()
  })

  test("a pull spins the reel frame by frame, lands upright and keeps the chief; pity gives a legendary", async () => {
    const h = host({ gacha: { owned: { lint: 1 }, sincePity: 29 } })
    h.mount("m", "renderSection")
    await h.settle(10)
    await runFrames(h)
    const pull = h.findNode("m", (n) => n.type === "Button" && JSON.stringify(n.props).includes("Pull"))!
    h.dispatch("m", pull, "tap", {})
    await h.settle()
    expect(texts(h)).toContain("Rolling…")
    const angles = new Set<unknown>()
    const reel = () => h.tree("m").nodes.get(h.findNode("m", (n) => n.type === "Icon" && "rotation" in n.props)!)!.props.rotation
    const frames = await runFrames(h, () => angles.add(reel()))
    expect(frames).toBeGreaterThan(20)
    expect(angles.size).toBeGreaterThan(10)
    expect(reel() ?? 0).toBe(0)
    expect(texts(h)).toContain("Cloud Chief")
    expect(texts(h)).toContain("Legendary")
    expect(h.calls.find((c) => c.name === "toast.show")?.params.title).toBe("Legendary: Cloud Chief")
    expect(h.calls.filter((c) => c.name === "app.storage.set").at(-1)?.params).toEqual({
      key: "gacha",
      value: { owned: { lint: 1, cloud: 1 }, sincePity: 0 }
    })
  })

  test("a Usage app problem says so instead of offering to add an account", async () => {
    const h = host()
    h.handlers["usage_app.status"] = ok({ state: "denied", problem: { code: "router.denied", message: "The router refused the read" }, providers: [] })
    h.mount("m", "renderSection")
    await h.settle(10)
    expect(h.findNode("m", (n) => n.type === "EmptyState" && n.props.message === "The router refused the read")).toBeDefined()
    expect(h.findNode("m", (n) => n.type === "EmptyState" && n.props.title === "No accounts")).toBeUndefined()
  })

  test("a failed refresh that kept the last reading still draws the reading", async () => {
    const h = host()
    h.handlers["usage_app.status"] = ok({ ...STATUS, problem: { code: "net.failed", message: "offline" } })
    h.mount("m", "renderSection")
    await h.settle(10)
    await runFrames(h)
    expect(texts(h)).toContain("72%")
  })

  test("the clock and the reads run once for every open view, and stop with the last one", async () => {
    const h = host()
    const repeating = () => [...h.timers.values()].filter((t) => t.repeat).map((t) => t.ms).sort((a, b) => a - b)
    h.mount("a", "renderSection")
    h.mount("b", "renderPage")
    h.mount("c", "renderPage")
    await h.settle(10)
    await runFrames(h)
    expect(repeating()).toEqual([15000, 300000, 900000])
    // The view that armed them closes: the others keep one set.
    h.global.__cmuxAppUnmount("a")
    await runFrames(h)
    expect(repeating()).toEqual([15000, 300000, 900000])
    h.global.__cmuxAppUnmount("b")
    await runFrames(h)
    expect(repeating()).toEqual([15000, 300000, 900000])
    h.global.__cmuxAppUnmount("c")
    await runFrames(h)
    expect(repeating()).toEqual([])
    // A view opened again starts them again.
    h.mount("d", "renderSection")
    await h.settle(10)
    expect(repeating()).toEqual([15000, 300000, 900000])
    expect(h.calls.filter((c) => c.name === "usage_app.status")).toHaveLength(1)
  })

  test("Pull waits for the saved chiefs, so an early pull can't count pity from 0 or be overwritten", async () => {
    const h = host()
    let answer = (_: unknown) => {}
    h.handlers["app.storage.get"] = (p) =>
      p.key === "gacha" ? new Promise((r) => (answer = r)) : { ok: true, body: { value: null } }
    h.mount("m", "renderSection")
    await h.settle(10)
    const pull = () => h.findNode("m", (n) => n.type === "Button" && JSON.stringify(n.props).includes("Pull"))!
    expect(h.tree("m").nodes.get(pull())!.props.disabled).toBe(true)
    h.dispatch("m", pull(), "tap", {})
    await h.settle()
    expect(texts(h)).not.toContain("Rolling…")
    answer({ ok: true, body: { value: { owned: { lint: 1 }, sincePity: 29 } } })
    await h.settle(10)
    expect(h.tree("m").nodes.get(pull())!.props.disabled).toBeFalsy()
    h.dispatch("m", pull(), "tap", {})
    await h.settle()
    await runFrames(h)
    expect(texts(h)).toContain("Cloud Chief")
  })

  test("closing the last view mid-spin stops the reel: no more frames, nothing kept, no toast", async () => {
    const h = host({ gacha: { owned: {}, sincePity: 29 } })
    h.mount("m", "renderSection")
    await h.settle(10)
    await runFrames(h)
    h.dispatch("m", h.findNode("m", (n) => n.type === "Button" && JSON.stringify(n.props).includes("Pull"))!, "tap", {})
    await h.settle()
    h.global.__cmuxAppUnmount("m")
    // At most the frame already armed fires, and it stops there.
    expect(await runFrames(h)).toBeLessThanOrEqual(1)
    expect(h.calls.some((c) => c.name === "app.storage.set" && c.params.key === "gacha")).toBe(false)
    expect(h.calls.some((c) => c.name === "toast.show")).toBe(false)
  })

  test("the New Tab page draws the same three cards", async () => {
    const h = host()
    h.mount("m", "renderPage")
    await h.settle(10)
    const panels = [...h.tree("m").nodes.values()].filter((n) => n.type === "Panel").map((n) => n.props.title)
    expect(panels).toEqual(["Today", "Usage", "Chief gacha"])
  })
})
