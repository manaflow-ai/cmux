// examples/extensions/leo-weather (the Leo collection) in the fake host: the sky it draws for each
// condition, the live reading, and bars that update in place so the renderer can spring them.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost } from "./fake-host.ts"

const dir = join(import.meta.dir, "../../../../..", "examples/extensions/leo-weather")
const ok = (value: unknown) => ({ ok: true, body: { value } })
let bundle = ""
beforeAll(async () => {
  bundle = await pack(dir)
})

const geocode = { results: [{ name: "Lisbon", admin1: "Lisbon", latitude: 38.7, longitude: -9.1 }] }
const forecast = (t0: number) => ({
  current: { time: "2026-11-16T13:45", temperature_2m: t0, apparent_temperature: t0 - 1, weather_code: 63, wind_speed_10m: 11.8, is_day: 1 },
  hourly: { time: Array.from({ length: 12 }, (_, i) => `2026-11-16T${String(13 + i).padStart(2, "0")}:00`), temperature_2m: Array.from({ length: 12 }, (_, i) => t0 + i) },
  daily: { temperature_2m_max: [24.2], temperature_2m_min: [15.1] }
})

function host(settings: Record<string, unknown>) {
  const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
  return new FakeHost(bundle, { app: { id: manifest.id, version: "1.0.0" }, settings, apiVersion: "1.0.0" })
}
const nodes = (h: FakeHost, m: string) => [...h.tree(m).nodes.entries()].map(([id, n]) => ({ id, ...n }))
const texts = (h: FakeHost, m: string) => nodes(h, m).filter((n) => n.type === "Text").map((n) => String(n.props.text))

describe("local/leo-weather", () => {
  test("every surface the manifest names is an export of the bundle", () => {
    const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
    for (const impl of Object.values(manifest.implements as Record<string, { export: string }>)) expect(bundle).toContain(`var ${impl.export} = `)
    expect(Object.keys(manifest.optionalScopes)).toEqual(["net:get.geojs.io"])
  })

  test("a preview draws its sky with no network: rain falls, the sun spins and glows, snow and stars", async () => {
    for (const [kind, preset] of [["rain", "rain"], ["snow", "snow"], ["night", "stars"]] as const) {
      const h = host({ preview: kind })
      expect(h.mount("m", "renderNewTab", { surface: "newTab" })).toBe("")
      await h.settle(5)
      expect(nodes(h, "m").find((n) => n.type === "Particles")?.props.preset).toBe(preset)
      expect(h.calls.filter((c) => c.name === "net.fetch")).toEqual([])
    }
    const h = host({ preview: "sun" })
    h.mount("m", "renderPane")
    await h.settle(5)
    const circles = nodes(h, "m").filter((n) => n.type === "Circle")
    expect(circles.find((n) => n.props.trim)?.props.loop).toEqual({ effect: "spin", period: 6 })
    expect(circles.find((n) => n.props.glow)?.props.glow).toMatchObject({ color: "#FFC83D" })
    expect(nodes(h, "m").find((n) => n.type === "ZStack" && (n.props.loop as { effect?: string } | undefined)?.effect === "float")).toBeUndefined()
    expect(nodes(h, "m").some((n) => (n.props.gradient as { colors?: string[] } | undefined)?.colors?.length === 2)).toBe(true)
  })

  test("reads the place's weather; a new reading updates the same bars in place", async () => {
    let t0 = 10
    const h = host({ place: "Lisbon" })
    h.handlers["net.fetch"] = (p) => ok({ status: 200, body: JSON.stringify(String(p.url).includes("geocoding") ? geocode : forecast(t0)) })
    h.mount("m", "renderNewTab", { surface: "newTab" })
    await h.settle(10)
    expect(texts(h, "m")).toContain("10°")
    expect(nodes(h, "m").find((n) => n.type === "Particles")?.props.preset).toBe("rain")
    const bars = () => nodes(h, "m").filter((n) => n.type === "Capsule" && n.props.animation === "snappy")
    const before = bars()
    expect(before.length).toBe(12)
    expect(before.every((b) => b.props.animation === "snappy")).toBe(true)
    // The refresh is Open-Meteo's own 15 minute cadence.
    expect([...h.timers.values()]).toContainEqual({ ms: 15 * 60_000, repeat: true })
    t0 = 20
    const [refresh] = [...h.timers.entries()].find(([, t]) => t.ms === 15 * 60_000)!
    h.global.__cmuxAppTimer(refresh)
    await h.settle(10)
    expect(texts(h, "m")).toContain("20°")
    expect(bars().map((b) => b.id)).toEqual(before.map((b) => b.id))
  })

  test("with no place and approximate location off it asks, and never looks up the IP", async () => {
    const h = host({})
    h.mount("m", "renderSection")
    await h.settle(5)
    expect(texts(h, "m")).toContain("Where are you?")
    expect(h.calls.filter((c) => c.name === "net.fetch")).toEqual([])
  })
})
