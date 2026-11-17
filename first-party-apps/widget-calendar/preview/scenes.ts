// Draws the packed widget in the fake host at a fixed instant with a fake calendar and returns the
// scene ops it sends, for the tests and the gallery fixtures (preview/build.ts).
// The instant: Tuesday, November 17, 2026, 1:12 PM in Los Angeles. Run with TZ=America/Los_Angeles.
import { FakeHost, type Op } from "cmux-extension-sdk/testing"

export const AT = Date.UTC(2026, 10, 17, 21, 12, 0)

export type Day = "busy" | "clear" | "allDay" | "empty" | "ask" | "denied" | "offMac"

export interface Render {
  size: "small" | "medium" | "large"
  day: Day
  settings?: Record<string, unknown>
  place?: "newtab" | "sidebar"
}

const HOUR = 3_600_000
/** Local wall time on the fixed day (offset 0 today, 1 tomorrow), in Los Angeles. */
const at = (dayOffset: number, hour: number, minute = 0) => {
  const d = new Date(AT)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + dayOffset, hour, minute).getTime()
}
const midnight = (dayOffset: number) => at(dayOffset, 0)

const ev = (id: string, title: string, start: number, minutes: number, color: string, location?: string, calendar = "home") => ({
  id, title, start, end: start + minutes * 60_000, allDay: false, calendar, color, ...(location ? { location } : {})
})
const allDay = (id: string, title: string, dayOffset: number, color: string) => ({
  id, title, start: midnight(dayOffset), end: midnight(dayOffset + 1) - 1000, allDay: true, calendar: "Family", color
})

const PURPLE = "#cc73e1", BLUE = "#1badf8", GREEN = "#63da38", ORANGE = "#ff9500", RED = "#ff2968"

/** Each day the gallery shows, as the host would answer it. */
export const DAYS: Record<Day, { access: string; events: unknown[] } | { error: string }> = {
  busy: {
    access: "granted",
    events: [
      ev("standup", "Team standup", at(0, 9, 30), 15, BLUE, "Zoom", "work"),
      ev("review", "Design review", at(0, 13, 30), 60, BLUE, "Room 4", "work"),
      ev("yoga", "Yoga Class", at(0, 16), 60, PURPLE, "Golden Gate Park"),
      ev("dinner", "Dinner with Ravi", at(0, 18), 90, GREEN, "Nopa"),
      ev("call", "Call Mom", at(0, 20, 30), 30, PURPLE),
      ev("coffee", "Pick up coffee", at(1, 8, 30), 30, GREEN, "Coffee Shop"),
      ev("1on1", "1:1 with Aziz", at(1, 11), 30, BLUE, "Zoom", "work"),
      ev("dentist", "Dentist", at(1, 15), 60, ORANGE, "Market St")
    ]
  },
  clear: {
    access: "granted",
    events: [
      ev("standup", "Team standup", at(0, 9, 30), 15, BLUE, "Zoom", "work"),
      ev("coffee", "Pick up coffee", at(1, 8, 30), 30, GREEN, "Coffee Shop"),
      ev("1on1", "1:1 with Aziz", at(1, 11), 30, BLUE, "Zoom", "work")
    ]
  },
  allDay: {
    access: "granted",
    events: [
      allDay("bday", "Maya's Birthday", 0, RED),
      ev("yoga", "Yoga Class", at(0, 16), 60, PURPLE, "Golden Gate Park"),
      allDay("trip", "Trip to Tahoe", 1, ORANGE),
      ev("coffee", "Pick up coffee", at(1, 8, 30), 30, GREEN, "Coffee Shop")
    ]
  },
  empty: { access: "granted", events: [] },
  ask: { access: "notDetermined", events: [] },
  denied: { access: "denied", events: [] },
  offMac: { error: "provider.unavailable" }
}

export async function renderScene(source: string, render: Render): Promise<{ ops: Op[]; host: FakeHost; calls: Array<[string, unknown]> }> {
  const host = new FakeHost("", { app: { id: "cmux/calendar", version: "1.0.0", locale: "en-US" }, apiVersion: "1.0.0", settings: {} })
  const calls: Array<[string, unknown]> = []
  const answer = DAYS[render.day]
  host.handlers = {
    "system_calendar.events": (params: unknown) => {
      calls.push(["system_calendar.events", params])
      return "error" in answer
        ? { ok: false, body: { code: answer.error, message: "unavailable", retryable: true } }
        : { ok: true, body: { value: answer } }
    },
    "system_calendar.request_access": (params: unknown) => {
      calls.push(["system_calendar.request_access", params])
      return { ok: true, body: { value: { access: "granted" } } }
    }
  }
  // Pin the clock before the app's script runs, so nothing reads the real time.
  host.eval(`Date.now = () => ${AT}`)
  host.eval(source)
  host.mount("w", "renderCalendar", {
    surface: "widget",
    size: render.size,
    place: render.place ?? "newtab",
    instance: `preview-${render.size}`,
    settings: render.settings ?? {},
    now: undefined
  })
  await host.settle()
  return { ops: host.batches("w").flat(), host, calls }
}

/** The nodes on screen after every batch, in tree order (a re-render removes and recreates nodes). */
export function visible(ops: Op[]): Op[] {
  const nodes = new Map<string, Op>()
  const children = new Map<string, string[]>()
  const parents = new Set<string>()
  let root: string | undefined
  for (const op of ops) {
    if (op.op === "create") {
      nodes.set(op.id, { ...op, props: { ...(op.props ?? {}) } })
      root ??= op.id
    } else if (op.op === "update") {
      const node = nodes.get(op.id)
      if (node) node.props = { ...(node.props ?? {}), ...(op.props ?? {}) }
    } else if (op.op === "remove") {
      nodes.delete(op.id)
    } else if (op.op === "children") {
      children.set(op.id, op.children ?? [])
      for (const c of op.children ?? []) parents.add(c)
    }
  }
  const out: Op[] = []
  const walk = (id: string) => {
    const node = nodes.get(id)
    if (!node) return
    out.push(node)
    for (const c of children.get(id) ?? []) walk(c)
  }
  if (root) walk(root)
  return out
}
