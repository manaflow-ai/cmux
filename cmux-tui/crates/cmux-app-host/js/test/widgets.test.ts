// The widget extensions (examples/extensions/widget-clock, widget-weather, widget-calendar,
// widget-todo) in the fake host, packed from src/main.ts: what each size shows, the reads it makes,
// and the to-do list it keeps. The same mounts write the scenes the webviews gallery draws
// (webviews/src/apps/scene/fixtures/widget-scenes.json): WIDGET_SCENES=write rewrites the file,
// otherwise the test fails when the file no longer matches what the widgets draw.
import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { pack } from "../../tools/pack.ts"
import { FakeHost, type Op } from "./fake-host.ts"

const root = join(import.meta.dir, "../../../../..")
const dir = (name: string) => join(root, "examples/extensions", name)
const NAMES = ["widget-clock", "widget-weather", "widget-calendar", "widget-todo"] as const
type Name = (typeof NAMES)[number]
const SIZES = ["small", "medium", "large"] as const
const built: Partial<Record<Name, string>> = {}

beforeAll(async () => {
  for (const name of NAMES) built[name] = await pack(dir(name))
})

// Monday 2026-11-16 14:05 UTC, read as local time (offset 0).
const AT = Date.UTC(2026, 10, 16, 14, 5)
const HOUR = 3_600_000
const ok = (value: unknown = null) => ({ ok: true, body: { value } })
const fetched = (body: unknown) => ok({ status: 200, headers: {}, body: JSON.stringify(body) })

function host(name: Name, settings: Record<string, unknown> = {}) {
  const manifest = JSON.parse(readFileSync(join(dir(name), "cmux-app.json"), "utf8"))
  const h = new FakeHost(built[name]!, { app: { id: manifest.id, version: "1.0.0" }, settings, apiVersion: "1.0.0" })
  h.eval(`Date.now = () => globalThis.__now; Date.prototype.getTimezoneOffset = () => 0; globalThis.__now = ${AT}`)
  return h
}

/** Every Text and title on screen, in tree order. */
function texts(h: FakeHost, mount = "m"): string[] {
  const tree = h.tree(mount)
  const out: string[] = []
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    for (const k of ["text", "title"]) if (typeof n.props[k] === "string" && n.props[k]) out.push(n.props[k] as string)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return out
}

/** The nodes reachable from the root (a removed subtree's descendants stay in FakeHost.tree). */
function live(h: FakeHost, mount = "m") {
  const tree = h.tree(mount)
  const out = new Map<string, { type: string; props: Record<string, unknown>; children: string[] }>()
  const walk = (id: string) => {
    const n = tree.nodes.get(id)
    if (!n) return
    out.set(id, n)
    n.children.forEach(walk)
  }
  walk(tree.root)
  return { root: tree.root, nodes: out }
}

function find(h: FakeHost, pred: (n: { type: string; props: Record<string, unknown> }) => boolean): string {
  for (const [id, n] of live(h).nodes) if (pred(n)) return id
  throw new Error("no such node on screen")
}

function count(h: FakeHost, type: string, mount = "m") {
  return [...live(h, mount).nodes.values()].filter((n) => n.type === type).length
}

function menuTitles(h: FakeHost): string[] {
  const panel = [...live(h).nodes.values()].find((n) => n.type === "Panel")!
  const menu = panel.props.menu as Array<{ title: string; children?: Array<{ title: string }> }>
  return menu.flatMap((m) => [m.title, ...(m.children ?? []).map((c) => c.title)])
}

// ---- Weather fixtures

const forecastBody = {
  current: { time: "2026-11-16T14:00", temperature_2m: 18.4, apparent_temperature: 17.2, weather_code: 2, is_day: 1 },
  hourly: {
    time: Array.from({ length: 48 }, (_, i) => `2026-11-${16 + Math.floor(i / 24)}T${String(i % 24).padStart(2, "0")}:00`),
    temperature_2m: Array.from({ length: 48 }, (_, i) => 10 + (i % 24) / 2),
    weather_code: Array.from({ length: 48 }, (_, i) => (i % 24 > 16 ? 61 : 1)),
    is_day: Array.from({ length: 48 }, (_, i) => (i % 24 >= 7 && i % 24 < 18 ? 1 : 0))
  },
  daily: {
    time: ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"],
    weather_code: [2, 61, 3, 0, 0, 80, 95],
    temperature_2m_max: [20.2, 17.6, 16.1, 19.4, 21.0, 18.3, 15.2],
    temperature_2m_min: [11.6, 10.2, 9.4, 8.8, 10.1, 12.0, 9.9]
  }
}

function weather(size: string) {
  const h = host("widget-weather", { size, place: "Lisbon", units: "celsius" })
  h.handlers["net.fetch"] = (p) =>
    p.url.startsWith("https://geocoding-api.open-meteo.com/") ? fetched({ results: [{ name: "Lisbon", latitude: 38.72, longitude: -9.14 }] }) : fetched(forecastBody)
  return h
}

// ---- Calendar fixtures

const ev = (id: string, title: string, startH: number, lengthH: number, extra: Record<string, unknown> = {}) => ({
  id,
  title,
  start: AT + startH * HOUR,
  end: AT + (startH + lengthH) * HOUR,
  allDay: false,
  calendar: "Work",
  ...extra
})
const EVENTS = [
  ev("standup", "Standup", -3, 0.5), // ended this morning: not shown
  ev("review", "Design review", -0.5, 1),
  ev("lunch", "Lunch with Sam", 1, 1, { location: "Cafe" }),
  ev("1on1", "One on one", 3, 0.5),
  ev("offsite", "Team offsite", 24 - 14, 24, { allDay: true }),
  ev("demo", "Demo day", 48 + 4, 1)
]

function calendar(size: string, access = "granted") {
  const h = host("widget-calendar", { size })
  let state = access
  h.handlers["system_calendar.events"] = () => ok({ access: state, events: state === "granted" ? EVENTS : [] })
  h.handlers["system_calendar.request_access"] = () => {
    state = "granted"
    return ok({ access: state })
  }
  return h
}

// ---- To-do fixtures

const ITEMS = [
  { id: "a", text: "Reply to the design thread", done: false },
  { id: "b", text: "Book flights", done: false },
  { id: "c", text: "Review the widget PR", done: true },
  { id: "d", text: "Water the plants", done: false },
  { id: "e", text: "Renew passport", done: false },
  { id: "f", text: "Call the bank", done: false }
]

function todo(size: string, saved: unknown = ITEMS) {
  const h = host("widget-todo", { size })
  const store: { items: unknown } = { items: saved }
  h.handlers["app.storage.get"] = () => ok(store.items ?? null)
  h.handlers["app.storage.set"] = (p) => {
    store.items = p.value
    return ok()
  }
  h.handlers["app.storage.delete"] = () => {
    store.items = null
    return ok()
  }
  return { h, store }
}

describe("widget-clock", () => {
  test("small: the weekday, the time and the date; no cities", () => {
    const h = host("widget-clock", { size: "small" })
    h.mount("m", "renderClock")
    expect(texts(h)).toEqual(["MONDAY", "14:05", "November 16"])
  })

  test("medium: three cities beside the time, in their own wall time", () => {
    const h = host("widget-clock", { size: "medium", zones: "America/New_York, Europe/London, Asia/Tokyo, Asia/Kolkata" })
    h.mount("m", "renderClock")
    expect(texts(h)).toEqual(["MONDAY", "14:05", "November 16", "New York", "09:05", "London", "14:05", "Tokyo", "23:05"])
  })

  test("large: up to six cities with their day and distance, a 12-hour clock, and the size menu", () => {
    const h = host("widget-clock", { size: "large", hour12: true, zones: "Asia/Tokyo, America/Los_Angeles, Mars/Base" })
    h.mount("m", "renderClock")
    expect(texts(h)).toEqual(["MONDAY", "2:05", "PM", "November 16", "Tokyo", "Today, +9h", "11:05 PM", "Los Angeles", "Today, −8h", "6:05 AM", "Base", "Not a time zone", "—"])
    expect(menuTitles(h)).toEqual(["Size", "Small", "Medium", "✓ Large"])
  })

  test("it ticks on the minute and reads nothing", () => {
    const h = host("widget-clock", {})
    h.mount("m", "renderClock")
    expect([...h.timers.values()]).toEqual([{ ms: 60_000 - (AT % 60_000) + 50, repeat: false }])
    expect(h.calls.filter((c) => c.name !== "app.settings.set")).toEqual([])
  })
})

describe("widget-weather", () => {
  test("small: the place, the temperature, the sky and today's range", async () => {
    const h = weather("small")
    h.mount("m", "renderWeather")
    await h.settle(10)
    expect(texts(h)).toEqual(["Lisbon", "18°", "⛅️", "Partly Cloudy", "H:20°  L:12°"])
  })

  test("medium: the next six hours start at this hour", async () => {
    const h = weather("medium")
    h.mount("m", "renderWeather")
    await h.settle(10)
    expect(texts(h)).toEqual([
      "Lisbon", "18°", "⛅️", "Partly Cloudy", "H:20°  L:12°",
      "Now", "⛅️", "17°", "3PM", "⛅️", "18°", "4PM", "⛅️", "18°", "5PM", "🌧️", "19°", "6PM", "🌧️", "19°", "7PM", "🌧️", "20°"
    ])
  })

  test("large: the hours and six days; one forecast read with the hours and days asked for", async () => {
    const h = weather("large")
    h.mount("m", "renderWeather")
    await h.settle(10)
    const t = texts(h)
    expect(t.slice(23)).toEqual([
      "Today", "⛅️", "12°", "20°", "Tue", "🌧️", "10°", "18°", "Wed", "☁️", "9°", "16°",
      "Thu", "☀️", "9°", "19°", "Fri", "☀️", "10°", "21°", "Sat", "🌧️", "12°", "18°"
    ])
    const reads = h.calls.filter((c) => c.name === "net.fetch").map((c) => c.params.url as string)
    expect(reads).toHaveLength(2)
    expect(reads[1]).toContain("&hourly=temperature_2m,weather_code,is_day")
    expect(reads[1]).toContain("&daily=weather_code,temperature_2m_max,temperature_2m_min")
  })

  test("no place: a field asks for one, and nothing is read", async () => {
    const h = host("widget-weather", {})
    h.mount("m", "renderWeather")
    await h.settle()
    expect(count(h, "TextField")).toBe(1)
    expect(h.calls.filter((c) => c.name === "net.fetch")).toEqual([])
  })
})

describe("widget-calendar", () => {
  test("small: the day and the date over the next event; one that ended is gone", async () => {
    const h = calendar("small")
    h.mount("m", "renderCalendar")
    await h.settle()
    expect(texts(h)).toEqual(["MONDAY", "16", "Design review", "Now, until 14:35"])
    expect(h.calls.find((c) => c.name === "system_calendar.events")!.params).toEqual({ days: 31, limit: 20 })
  })

  test("medium: the next three events", async () => {
    const h = calendar("medium")
    h.mount("m", "renderCalendar")
    await h.settle()
    expect(texts(h)).toEqual(["MONDAY", "16", "Design review", "Now, until 14:35", "Lunch with Sam", "15:05 to 16:05", "One on one", "17:05 to 17:35"])
  })

  test("large: the month with today marked, then five events by day", async () => {
    const h = calendar("large", "granted")
    h.mount("m", "renderCalendar")
    await h.settle()
    const t = texts(h)
    expect(t.slice(0, 2)).toEqual(["November", "Monday"])
    // November 2026 starts on a Sunday: five weeks, no blanks before the 1st.
    expect(t.slice(9, 16)).toEqual(["1", "2", "3", "4", "5", "6", "7"])
    const today = [...live(h).nodes.values()].find((n) => n.type === "Text" && n.props.text === "16")!
    expect([today.props.weight, today.props.color]).toEqual(["bold", "accent"])
    expect(t.slice(-10)).toEqual([
      "Design review", "Now, until 14:35",
      "Lunch with Sam", "15:05 to 16:05",
      "One on one", "17:05 to 17:35",
      "Team offsite", "Tomorrow, All day",
      "Demo day", "Wednesday, November 18, 18:05 to 19:05"
    ])
  })

  test("never asks on its own: a click on Show my calendar asks once, with the click's gesture", async () => {
    const h = calendar("small", "notDetermined")
    h.mount("m", "renderCalendar")
    await h.settle()
    expect(texts(h)).toEqual(["MONDAY", "16", "See your next events here.", "Show my calendar"])
    expect(h.calls.filter((c) => c.name === "system_calendar.request_access")).toEqual([])
    h.dispatch("m", find(h, (n) => n.type === "Button" && n.props.title === "Show my calendar"), "tap", { gesture: "g1" })
    await h.settle()
    const asks = h.calls.filter((c) => c.name === "system_calendar.request_access")
    expect(asks.map((c) => c.options.gesture)).toEqual(["g1"])
    expect(texts(h)).toEqual(["MONDAY", "16", "Design review", "Now, until 14:35"])
  })

  test("access turned off says where to turn it on", async () => {
    const h = calendar("medium", "denied")
    h.mount("m", "renderCalendar")
    await h.settle()
    expect(texts(h)[2]).toContain("System Settings > Privacy & Security > Calendars")
    expect(count(h, "Button")).toBe(0)
  })
})

describe("widget-todo", () => {
  test("small: how many are left and the first three open ones; no field", async () => {
    const { h } = todo("small")
    h.mount("m", "renderTodo")
    await h.settle()
    expect(texts(h)).toEqual(["To-do", "5", "Reply to the design thread", "Book flights", "Water the plants", "2 more"])
    expect(count(h, "TextField")).toBe(0)
  })

  test("medium: four open ones and a field that adds one and saves the list", async () => {
    const { h, store } = todo("medium")
    h.mount("m", "renderTodo")
    await h.settle()
    expect(texts(h)).toEqual(["To-do", "5", "Reply to the design thread", "Book flights", "Water the plants", "Renew passport", "1 more"])
    h.dispatch("m", find(h, (n) => n.type === "TextField"), "submit", { text: "  Buy milk  " })
    await h.settle()
    expect((store.items as Array<{ text: string }>).at(-1)).toMatchObject({ text: "Buy milk", done: false })
    expect(texts(h)[1]).toBe("6")
  })

  test("large: ticking moves an item to Done, Clear removes the ticked ones, and a new host reads the saved list", async () => {
    const { h, store } = todo("large")
    h.mount("m", "renderTodo")
    await h.settle()
    expect(texts(h)).toEqual(["To-do", "5", "Reply to the design thread", "Book flights", "Water the plants", "Renew passport", "Call the bank", "Done", "Clear", "Review the widget PR"])
    const circle = find(h, (n) => n.type === "Icon" && n.props.symbol === "circle")
    h.dispatch("m", circle, "tap", { gesture: "g1" })
    await h.settle()
    expect(texts(h).slice(0, 2)).toEqual(["To-do", "4"])
    expect(texts(h).slice(-3)).toEqual(["Clear", "Reply to the design thread", "Review the widget PR"])
    h.dispatch("m", find(h, (n) => n.type === "Button" && n.props.title === "Clear"), "tap", { gesture: "g2" })
    await h.settle()
    expect((store.items as Array<{ id: string }>).map((i) => i.id)).toEqual(["b", "d", "e", "f"])
    const again = todo("large", store.items).h
    again.mount("m", "renderTodo")
    await again.settle()
    expect(texts(again)).toEqual(["To-do", "4", "Book flights", "Water the plants", "Renew passport", "Call the bank"])
  })

  test("an empty or broken saved list is an empty list that says so", async () => {
    const { h } = todo("medium", [{ nope: 1 }, "x"])
    h.mount("m", "renderTodo")
    await h.settle()
    expect(texts(h)).toEqual(["To-do", "0", "Nothing to do"])
    expect(count(h, "TextField")).toBe(1)
  })
})

// ---- The gallery's scenes: each widget at each size, as the ops its render export emits.

const RENDER: Record<Name, string> = { "widget-clock": "renderClock", "widget-weather": "renderWeather", "widget-calendar": "renderCalendar", "widget-todo": "renderTodo" }

async function scene(name: Name, size: string): Promise<Op[]> {
  const h =
    name === "widget-clock" ? host(name, { size, zones: "America/New_York, Europe/London, Asia/Tokyo, Asia/Kolkata, Australia/Sydney, America/Los_Angeles" })
    : name === "widget-weather" ? weather(size)
    : name === "widget-calendar" ? calendar(size)
    : todo(size).h
  h.mount("m", RENDER[name])
  await h.settle(10)
  // The final tree as one batch: a create per node, then each node's children, then the root.
  const tree = live(h)
  const ops: Op[] = []
  for (const [id, n] of tree.nodes) ops.push({ op: "create", id, type: n.type, props: n.props })
  for (const [id, n] of tree.nodes) if (n.children.length) ops.push({ op: "children", id, children: n.children })
  ops.push({ op: "root", id: tree.root })
  return ops
}

test("the gallery's widget scenes match what the widgets draw", async () => {
  const scenes: Record<string, Op[]> = {}
  for (const name of NAMES) for (const size of SIZES) scenes[`${name.replace("widget-", "")}.${size}`] = await scene(name, size)
  const file = join(root, "webviews/src/apps/scene/fixtures/widget-scenes.json")
  const json = `${JSON.stringify(scenes, null, 1)}\n`
  if (process.env.WIDGET_SCENES === "write") writeFileSync(file, json)
  // Compared as data: the webviews formatter owns the file's whitespace.
  expect(JSON.parse(readFileSync(file, "utf8"))).toEqual(JSON.parse(json))
})
