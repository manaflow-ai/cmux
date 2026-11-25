#!/usr/bin/env bun
// Writes preview/scenes.json: the scene each gallery state draws, made by running the built widget
// (dist/main.js) in the fake host against the invented Open-Meteo answers in fixtures.ts. The
// gallery entry (webviews/src/apps/scene/WeatherWidget.gallery.tsx) draws these with the real
// scene renderer, so a state is exactly what the widget emits. Rerun after changing src/:
//   bun cmux-tui/crates/cmux-app-host/tools/pack.ts first-party-apps/widget-weather
//   bun first-party-apps/widget-weather/preview/build.ts            (--check: exit 1 when stale)
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost } from "cmux-extension-sdk/testing"
import type { GeoJS, OpenMeteoForecast } from "../src/model.ts"
import { clearDay, clearNight, places, rainDay, snow } from "./fixtures.ts"

const dir = join(import.meta.dir, "..")
const built = readFileSync(join(dir, "dist/main.js"), "utf8")

type Size = "small" | "medium" | "large"
interface State {
  size: Size
  forecast?: OpenMeteoForecast
  ip?: GeoJS
  locale?: string
  settings?: Record<string, unknown>
  offline?: boolean
}

export const STATES: Record<string, State> = {
  "small-clear-day": { size: "small", forecast: clearDay, ip: places.cupertino, locale: "en-US" },
  "small-clear-night": { size: "small", forecast: clearNight, ip: places.tokyo, locale: "en" },
  "small-plain": { size: "small", forecast: clearDay, ip: places.cupertino, locale: "en-US", settings: { look: "plain" } },
  "small-no-network": { size: "small", offline: true },
  "medium-clear-day": { size: "medium", forecast: clearDay, ip: places.cupertino, locale: "en-US" },
  "medium-rain": { size: "medium", forecast: rainDay, ip: places.lisbon, locale: "en" },
  "medium-plain-rain": { size: "medium", forecast: rainDay, ip: places.lisbon, locale: "en", settings: { look: "plain" } },
  "large-clear-night": { size: "large", forecast: clearNight, ip: places.tokyo, locale: "en" },
  "large-snow": { size: "large", forecast: snow, ip: places.denver, locale: "en-US" }
}

type Op = { op: string; id: string; type?: string; props?: Record<string, unknown>; children?: string[] }

async function scene(state: State): Promise<Op[]> {
  const h = new FakeHost(built, { app: { id: "cmux/weather", version: "1.0.0" }, settings: state.settings ?? {}, apiVersion: "1.0.0", locale: state.locale ?? "en" })
  const ok = (value: unknown) => ({ ok: true, body: { value } })
  h.handlers["net.fetch"] = (p) => {
    if (state.offline) return { ok: false, body: { code: "scope.missing", message: "not granted", retryable: false } }
    const body = String(p.url).includes("geojs") ? state.ip : state.forecast
    return ok({ status: 200, body: JSON.stringify(body) })
  }
  h.handlers["app.storage.get"] = () => ok(null)
  h.handlers["app.storage.set"] = () => ok(null)
  h.mount("w", "renderWeather", { surface: "widget", place: "newtab", size: state.size, instance: "preview", settings: {}, refresh: { everySeconds: 900 } })
  await h.settle(30)
  // The final tree as fresh create ops, children and root (one batch a renderer applies from empty).
  const tree = h.tree("w")
  const ops: Op[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)!
    const props = Object.fromEntries(Object.entries(n.props).filter(([, v]) => v !== null && v !== undefined))
    ops.push({ op: "create", id, type: n.type, props })
    n.children.forEach(walk)
    if (n.children.length) ops.push({ op: "children", id, children: n.children })
  }
  walk(tree.root)
  ops.push({ op: "root", id: tree.root })
  return ops
}

const out: Record<string, { size: Size; ops: Op[] }> = {}
for (const [name, state] of Object.entries(STATES)) out[name] = { size: state.size, ops: await scene(state) }
const file = join(import.meta.dir, "scenes.json")
const text = `${JSON.stringify(out, null, 1)}\n`
if (process.argv.includes("--check")) {
  if (readFileSync(file, "utf8") !== text) {
    console.error("preview/scenes.json is stale: run bun first-party-apps/widget-weather/preview/build.ts")
    process.exit(1)
  }
} else writeFileSync(file, text)
