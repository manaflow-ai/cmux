// Clock widget: the time and the date as a card you add to the sidebar, in the three sizes system
// widgets come in. It imports nothing but the public SDK.
// - Small: the time, large, over the day and the date.
// - Medium: the same, with up to three other cities beside it.
// - Large: the time and the date over up to six cities, each with how far it is from you.
// - The size, the cities and the 12-hour clock are the extension's settings (Settings > Apps >
//   Clock widget); right-click the card to change its size there and then.
// - It redraws once a minute, on the minute, and asks no host for anything: the zone rules come
//   from cmux.time.zone(), cmux's own time zone database.

import { Button, cmux, computed, ForEach, HStack, Menu, onCleanup, Panel, signal, Spacer, Text, VStack, type View } from "cmux-extension-sdk"

export type Size = "small" | "medium" | "large"
export const SIZES: Size[] = ["small", "medium", "large"]
export const DEFAULT_ZONES = "America/New_York, Europe/London, Asia/Tokyo"
const MINUTE = 60_000
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

export interface City { zone: string; name: string; time: string; detail: string; problem: boolean }

const two = (n: number) => String(n).padStart(2, "0")

export function sizeOf(setting: unknown): Size {
  return SIZES.includes(setting as Size) ? (setting as Size) : "small"
}

/** A wall time read through a Date's UTC getters. */
export function clockText(wall: Date, hour12: boolean): { time: string; period: string } {
  const h = wall.getUTCHours()
  const m = two(wall.getUTCMinutes())
  if (!hour12) return { time: `${two(h)}:${m}`, period: "" }
  return { time: `${h % 12 || 12}:${m}`, period: h < 12 ? "AM" : "PM" }
}

/** The local wall clock at `now` as a Date whose UTC getters read local time. */
function localWall(now: number): Date {
  return new Date(now - new Date(now).getTimezoneOffset() * MINUTE)
}

export function dateLine(now: number): { weekday: string; date: string } {
  const d = localWall(now)
  return { weekday: DAYS[d.getUTCDay()]!, date: `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}` }
}

/** "America/Los_Angeles" is "Los Angeles". */
export function cityName(zone: string): string {
  return (zone.split("/").at(-1) ?? zone).replace(/_/g, " ")
}

function distance(minutes: number): string {
  if (minutes === 0) return "Same time"
  const sign = minutes > 0 ? "+" : "−"
  const abs = Math.abs(minutes)
  return `${sign}${Math.floor(abs / 60)}${abs % 60 ? `:${two(abs % 60)}` : ""}h`
}

/** One city: its wall time at `now` and how it compares with yours ("Tomorrow, +9h"). */
export function city(zone: string, now: number, hour12: boolean): City {
  try {
    const z = cmux.time.zone(zone, now) as ReturnType<typeof cmux.time.zone> | Promise<unknown>
    // A cmux older than cmux.time sends the call to the host, which refuses it later.
    if (z instanceof Promise) {
      z.catch(() => {})
      throw { code: "operation.unsupported" }
    }
    const localOffset = -new Date(now).getTimezoneOffset()
    const wall = new Date(now + z.offsetMinutes * MINUTE)
    const local = localWall(now)
    const dayDelta = Math.round((Date.UTC(wall.getUTCFullYear(), wall.getUTCMonth(), wall.getUTCDate()) - Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate())) / 86_400_000)
    const day = dayDelta === 0 ? "Today" : dayDelta > 0 ? "Tomorrow" : "Yesterday"
    const t = clockText(wall, hour12)
    return { zone, name: cityName(zone), time: t.period ? `${t.time} ${t.period}` : t.time, detail: `${day}, ${distance(z.offsetMinutes - localOffset)}`, problem: false }
  } catch (error) {
    const e = error as { code?: string }
    return { zone, name: cityName(zone), time: "—", detail: e?.code === "operation.unsupported" ? "Update cmux" : "Not a time zone", problem: true }
  }
}

export function zonesFrom(setting: unknown): string[] {
  const text = typeof setting === "string" && setting.trim() ? setting : DEFAULT_ZONES
  const seen = new Set<string>()
  return text.split(",").map((z) => z.trim()).filter((z) => z && !seen.has(z) && seen.add(z))
}

/** The right-click menu every widget card shares: its size, then the card's own entries. */
export function sizeMenu(current: () => Size): View {
  const pick = (size: Size, title: string) =>
    Button(current() === size ? `✓ ${title}` : title, () => void cmux.app.settings.set({ size }).catch(() => undefined))
  return Menu("Size", [pick("small", "Small"), pick("medium", "Medium"), pick("large", "Large")])
}

const [now, setNow] = signal(Date.now())

export function renderClock(): View {
  setNow(Date.now())
  // Tick just after each minute starts; each one-shot timer arms the next, and the view's
  // cleanup clears the one pending.
  let timer = 0
  let open = true
  const arm = () => {
    timer = cmux.timer.after(MINUTE - (Date.now() % MINUTE) + 50, () => {
      setNow(Date.now())
      if (open) arm()
    })
  }
  arm()
  onCleanup(() => {
    open = false
    cmux.timer.clear(timer)
  })
  const settings = computed(() => cmux.app.settings())
  const size = computed(() => sizeOf(settings().size))
  const hour12 = computed(() => settings().hour12 === true)
  const local = computed(() => clockText(localWall(now()), hour12()))
  const day = computed(() => dateLine(now()))
  const cities = computed(() => {
    const max = size() === "large" ? 6 : size() === "medium" ? 3 : 0
    return zonesFrom(settings().zones).slice(0, max).map((zone) => city(zone, now(), hour12()))
  })

  const face = (font: "largeTitle" | "title") =>
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => day().weekday.toUpperCase()).font("caption").weight("semibold").color(cmux.theme.accent),
      HStack({ spacing: 4 }, [
        Text(() => local().time).font(font).weight("semibold").monospaced(),
        () => (local().period ? Text(() => local().period).font("headline").color(cmux.theme.text.secondary) : null)
      ]),
      Text(() => day().date).font("subheadline").color(cmux.theme.text.secondary)
    ])

  const cityColumn = () =>
    VStack({ spacing: 6, alignment: "trailing" }, [
      ForEach({ items: cities, key: (c) => c.zone }, (c) =>
        VStack({ spacing: 0, alignment: "trailing" }, [
          Text(() => c().name).font("caption").color(cmux.theme.text.secondary).lineLimit(1),
          Text(() => c().time).font("headline").monospaced().color(() => (c().problem ? cmux.theme.warning : cmux.theme.text.primary))
        ])
      )
    ])

  const cityRows = () =>
    VStack({ spacing: 8 }, [
      ForEach({ items: cities, key: (c) => c.zone }, (c) =>
        HStack({ spacing: 8 }, [
          VStack({ spacing: 0, alignment: "leading" }, [
            Text(() => c().name).font("headline").lineLimit(1),
            Text(() => c().detail).font("caption").color(() => (c().problem ? cmux.theme.warning : cmux.theme.text.secondary))
          ]),
          Spacer(),
          Text(() => c().time).font("title3").weight("medium").monospaced()
        ])
      )
    ])

  return Panel({ style: "card", spacing: 10 }, [
    () => {
      const s = size()
      if (s === "small") return face("largeTitle")
      if (s === "medium") return HStack({ spacing: 12 }, [face("largeTitle"), Spacer(), cityColumn()])
      return VStack({ spacing: 12 }, [face("largeTitle"), cityRows()])
    }
  ]).contextMenu(() => [sizeMenu(size)])
}
