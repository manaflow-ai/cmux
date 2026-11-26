import { beforeAll, describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { FakeHost, manifestSchema, pack, SchemaValidator } from "cmux-extension-sdk/testing"
import { clearDay, clearNight, places, rainDay, snow } from "../preview/fixtures.ts"
import { describe as condition, hourLabel, localeRegion, shown, skyFor, toForecast, unitsFor, weekday, weekRange } from "../src/model.ts"

const dir = join(import.meta.dir, "..")
const manifest = JSON.parse(readFileSync(join(dir, "cmux-app.json"), "utf8"))
let built = ""
beforeAll(async () => {
  built = await pack(dir)
})

const ok = (value: unknown) => ({ ok: true, body: { value } })
const fail = (code: string, message = code) => ({ ok: false, body: { code, message, retryable: false } })
const json = (body: unknown, status = 200) => ok({ status, body: JSON.stringify(body) })

/** The mount context cmux.widget/1 passes (the runtime adds now()). */
const ctx = (size: "small" | "medium" | "large", place = "newtab") => ({ surface: "widget", place, size, instance: "w1", settings: {}, refresh: { everySeconds: 900 } })

interface Options {
  settings?: Record<string, unknown>
  locale?: string
  forecast?: unknown
  ip?: unknown
  geocode?: unknown
  storage?: Record<string, unknown>
  net?: (url: string) => unknown
}

function host(o: Options = {}) {
  const storage = new Map(Object.entries(o.storage ?? {}))
  const h = new FakeHost(built, { app: { id: manifest.id, version: manifest.version }, settings: o.settings ?? {}, apiVersion: "1.0.0", locale: o.locale ?? "en" })
  h.handlers["net.fetch"] = (p) => {
    const url = String(p.url)
    if (o.net) return o.net(url) as never
    if (url.includes("get.geojs.io")) return json(o.ip ?? places.cupertino)
    if (url.includes("geocoding-api")) return json(o.geocode ?? { results: [] })
    return json(o.forecast ?? clearDay)
  }
  h.handlers["app.storage.get"] = (p) => ok(storage.get(p.key) ?? null)
  h.handlers["app.storage.set"] = (p) => {
    storage.set(p.key, p.value)
    return ok(null)
  }
  return { h, storage }
}

function drawn(h: FakeHost, mount: string) {
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
const texts = (h: FakeHost, m: string) => drawn(h, m).filter((n) => n.type === "Text").map((n) => String(n.props.text))
const symbols = (h: FakeHost, m: string) => drawn(h, m).filter((n) => n.type === "Icon").map((n) => String(n.props.symbol))
const fetched = (h: FakeHost) => h.calls.filter((c) => c.name === "net.fetch").map((c) => String(c.params.url))

describe("manifest", () => {
  test("is a v2 manifest the schema accepts, a store app (not bundled) with a widget in three sizes", () => {
    const errors = new SchemaValidator(manifestSchema()).validate(manifest)
    expect(errors).toEqual([])
    expect(manifest.implements["cmux.widget/1"].options).toMatchObject({ sizes: ["small", "medium", "large"], places: ["newtab", "sidebar"], refresh: { everySeconds: 900 } })
    expect(built).toContain("renderWeather: () => renderWeather")
    expect(() => readFileSync(join(dir, "BUNDLED"))).toThrow()
    readFileSync(join(dir, "STORE"))
    readFileSync(join(dir, manifest.icon))
  })

  test("every text field fits the v2 cap of 300 characters (the host silently drops a longer package)", () => {
    const long: string[] = []
    const walk = (value: unknown, path: string) => {
      if (typeof value === "string") {
        if (value.length > 300) long.push(`${path} (${value.length})`)
      } else if (Array.isArray(value)) value.forEach((v, i) => walk(v, `${path}[${i}]`))
      else if (value && typeof value === "object") for (const [k, v] of Object.entries(value)) walk(v, `${path}.${k}`)
    }
    walk(manifest, "$")
    expect(long).toEqual([])
  })

  test("imports nothing but the public SDK and its own files", () => {
    for (const file of ["main.ts", "model.ts", "sample.ts"]) {
      const src = readFileSync(join(dir, "src", file), "utf8")
      for (const [, a, b] of src.matchAll(/^import [^\n]*?from\s+"([^"]+)"|^} from "([^"]+)"/gm)) expect(["cmux-extension-sdk", "./model.ts", "./sample.ts"]).toContain((a ?? b)!)
    }
  })
})

describe("model", () => {
  test("units follow the locale's region, else the place's country; the setting overrides both", () => {
    expect(localeRegion("en-US")).toBe("US")
    expect(localeRegion("en_GB")).toBe("GB")
    expect(localeRegion("zh-Hant-TW")).toBe("TW")
    expect(localeRegion("en")).toBe("")
    expect(unitsFor("en-US", "auto")).toEqual({ fahrenheit: true, twelveHour: true })
    expect(unitsFor("en-GB", "auto", "US")).toEqual({ fahrenheit: false, twelveHour: false })
    expect(unitsFor("en", "auto", "US")).toEqual({ fahrenheit: true, twelveHour: true })
    expect(unitsFor("en", "auto", "PT")).toEqual({ fahrenheit: false, twelveHour: false })
    expect(unitsFor("en-US", "celsius").fahrenheit).toBe(false)
    expect(unitsFor("de-DE", "fahrenheit").fahrenheit).toBe(true)
  })

  test("temperatures convert and round as Weather shows them, never -0", () => {
    const f = { fahrenheit: true, twelveHour: true }
    const c = { fahrenheit: false, twelveHour: false }
    expect(shown(21.1, f)).toBe(70)
    expect(shown(-0.4, c)).toBe(0)
    expect(Object.is(shown(-0.4, c), -0)).toBe(false)
    expect(shown(-3.4, c)).toBe(-3)
  })

  test("conditions read as Apple names them, by day and night", () => {
    expect(condition(0, true)).toEqual({ text: "Sunny", symbol: "sun.max.fill" })
    expect(condition(0, false)).toEqual({ text: "Clear", symbol: "moon.stars.fill" })
    expect(condition(63, true).text).toBe("Rain")
    expect(condition(95, true).symbol).toBe("cloud.bolt.rain.fill")
    expect(skyFor(0, false)).toBe("clear-night")
    expect(skyFor(63, true)).toBe("rain-day")
  })

  test("the strip starts at the hour after now; the days start today", () => {
    const f = toForecast(clearDay)
    expect(f.hours.map((h) => h.time.slice(11))).toEqual(["10:00", "11:00", "12:00", "13:00", "14:00", "15:00"])
    expect(f.days[0]).toMatchObject({ today: true, date: "2026-06-05" })
    expect(f.days).toHaveLength(6)
    expect(hourLabel("2026-06-05T00:00", true)).toBe("12 AM")
    expect(hourLabel("2026-06-05T12:00", true)).toBe("12 PM")
    expect(hourLabel("2026-06-05T09:00", false)).toBe("09")
    expect(weekday("2026-11-16")).toBe("Mon")
    // A strip that crosses midnight keeps going into tomorrow.
    expect(toForecast(clearNight).hours.map((h) => h.time.slice(11))).toEqual(["23:00", "00:00", "01:00", "02:00", "03:00", "04:00"])
  })

  test("today's range holds the current reading; the week's span covers every day", () => {
    const f = toForecast({ ...clearDay, current: { ...clearDay.current, temperature_2m: 30 } })
    expect(f.high).toBe(30)
    const span = weekRange(toForecast(snow).days, { fahrenheit: false, twelveHour: false })
    expect(span).toEqual({ min: -7, max: 7 })
  })
})

describe("the widget", () => {
  test("a fresh install shows real weather with no setup: the town from the internet address, in its units", async () => {
    const { h, storage } = host()
    expect(h.mount("s", "renderWeather", ctx("small"))).toBe("")
    await h.settle(20)
    expect(texts(h, "s")).toEqual(["Cupertino", "70°", "Sunny", "H:75° L:59°"])
    expect(symbols(h, "s")).toEqual(["location.fill", "sun.max.fill"])
    expect(fetched(h)).toEqual(["https://get.geojs.io/v1/ip/geo.json", expect.stringContaining("https://api.open-meteo.com/v1/forecast?latitude=37.323&longitude=-122.032")])
    expect(storage.get("reading")).toMatchObject({ key: "", place: { name: "Cupertino" } })
    // The sky behind it is the clear day's blue.
    expect(drawn(h, "s")[0]!.props.background).toBe("#3A86D4")
  })

  test("medium adds six hours; large adds the days with range bars", async () => {
    const { h } = host({ locale: "en-US" })
    h.mount("m", "renderWeather", ctx("medium"))
    h.mount("l", "renderWeather", ctx("large"))
    await h.settle(20)
    expect(texts(h, "m")).toEqual(["Cupertino", "70°", "Sunny", "H:75° L:59°", "10 AM", "77°", "11 AM", "80°", "12 PM", "81°", "1 PM", "81°", "2 PM", "85°", "3 PM", "88°"])
    const large = texts(h, "l")
    expect(large.slice(16)).toEqual(["Today", "59°", "75°", "Sat", "57°", "79°", "Sun", "55°", "75°", "Mon", "54°", "70°", "Tue", "52°", "64°", "Wed", "54°", "72°"])
    // Two widgets, one read of each source.
    expect(fetched(h)).toHaveLength(2)
  })

  test("a typed place is looked up, shown in its own units, with no location arrow", async () => {
    const { h } = host({
      settings: { place: "Lisbon" },
      forecast: rainDay,
      geocode: { results: [{ name: "Lisbon", admin1: "Lisbon", country: "Portugal", country_code: "PT", latitude: 38.716, longitude: -9.133 }] }
    })
    h.mount("s", "renderWeather", ctx("small"))
    await h.settle(20)
    expect(texts(h, "s")).toEqual(["Lisbon", "14°", "Rain", "H:16° L:11°"])
    expect(symbols(h, "s")).toEqual(["cloud.rain.fill"])
    expect(fetched(h)[0]).toBe("https://geocoding-api.open-meteo.com/v1/search?count=1&name=Lisbon")
    expect(drawn(h, "s")[0]!.props.background).toBe("#4F6274")
  })

  test("the Units setting overrides; a night sky is navy; 24-hour clocks outside the US", async () => {
    const { h } = host({ settings: { units: "celsius" }, ip: places.tokyo, forecast: clearNight })
    h.mount("m", "renderWeather", ctx("medium"))
    await h.settle(20)
    expect(texts(h, "m").slice(0, 6)).toEqual(["Tokyo", "10°", "Clear", "H:16° L:8°", "23", "9°"])
    expect(drawn(h, "m")[0]!.props.background).toBe("#14203A")
  })

  test("the plain look follows the theme instead of painting a sky", async () => {
    const { h } = host({ settings: { look: "plain" } })
    h.mount("s", "renderWeather", ctx("small"))
    await h.settle(20)
    expect(drawn(h, "s")[0]!.props.background ?? null).toBeNull()
    expect(drawn(h, "s").find((n) => n.type === "Text")!.props.color).toBe("primary")
  })

  test("a kept reading draws before any network read, and a young one is not read again", async () => {
    const first = host()
    first.h.mount("s", "renderWeather", ctx("small"))
    await first.h.settle(20)
    const kept = Object.fromEntries(first.storage)
    const { h } = host({ storage: kept })
    h.mount("s", "renderWeather", ctx("small"))
    await h.settle(20)
    expect(texts(h, "s")).toEqual(["Cupertino", "70°", "Sunny", "H:75° L:59°"])
    expect(fetched(h)).toEqual([])
  })

  test("without network access it says how to allow it", async () => {
    const { h } = host({ net: () => fail("scope.missing", "net:get.geojs.io is not granted") })
    h.mount("s", "renderWeather", ctx("small"))
    await h.settle(20)
    expect(texts(h, "s")).toEqual(["Weather", "--°", "Allow network access for Weather in Settings > Apps."])
  })

  test("the host's tick re-reads only when the reading is older than ten minutes, with no timer of its own", async () => {
    const { h } = host()
    h.mount("s", "renderWeather", ctx("small"))
    const start = Date.now()
    h.tick("s", start)
    await h.settle(20)
    expect([...h.timers.values()]).toEqual([])
    const reads = () => fetched(h).filter((u) => u.includes("api.open-meteo.com")).length
    expect(reads()).toBe(1)
    // A tick inside the reuse window reads nothing.
    h.tick("s", start + 60_000)
    await h.settle(20)
    expect(reads()).toBe(1)
  })

  test("the Add Widget preview draws the sample and reads or writes nothing", async () => {
    const { h, storage } = host({ locale: "en-US" })
    h.mount("p", "renderWeather", { ...ctx("medium"), preview: true })
    await h.settle(20)
    expect(texts(h, "p").slice(0, 4)).toEqual(["Cupertino", "70°", "Sunny", "H:75° L:59°"])
    expect(h.calls.filter((c) => c.name !== "app.storage.get")).toEqual([])
    expect(storage.size).toBe(0)
  })

  test("an older host with no clock still refreshes on a 15 minute timer that ends with the view", async () => {
    const { h } = host()
    h.mount("s", "renderWeather", { size: "small", place: "newtab" })
    await h.settle(20)
    expect([...h.timers.values()]).toEqual([{ ms: 15 * 60_000, repeat: true }])
  })

  test("the sidebar uses the tighter inset", async () => {
    const { h } = host()
    h.mount("s", "renderWeather", ctx("small", "sidebar"))
    await h.settle(20)
    expect(drawn(h, "s")[0]!.props.padding).toBe(12)
  })
})
