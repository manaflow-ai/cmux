import { beforeEach, describe, expect, test } from "bun:test"
import { busyLabel } from "../src/busy.ts"
import { assertionDetail, assertionTitle, nextChangeFor, nextTextChange, timeLeftText } from "../src/format.ts"
import { setLanguage } from "../src/l10n.ts"
import { applyEvent, emptyState, fromList, normalizeAssertion, running, soonestEnd, type Assertion } from "../src/model.ts"
import { checkCreate, checkRelease, invokerOf } from "../src/policy.ts"
import { presetRequest } from "../src/presets.ts"
import { commandAssertion, hourAssertion, listValue, stoppedAssertion } from "../preview/fixtures.ts"

const MIN = 60_000
const NOW = Date.parse("2026-10-02T12:00:00Z")

beforeEach(() => setLanguage("en"))

describe("presets -> power.assertion.create params", () => {
  test("until stopped: display and Mac, no timeout, no handle", () => {
    const r = presetRequest("untilStopped")
    expect(r).toEqual({ ok: true, params: { kinds: ["display", "idle"], reason: "cmux Caffeinate: Until stopped" } })
  })

  test("for 1 hour: timeout 3600 s", () => {
    const r = presetRequest("hour")
    expect(r.ok && r.params).toEqual({ kinds: ["display", "idle"], reason: "cmux Caffeinate: For 1 hour", timeout_s: 3600 })
  })

  test("custom duration in minutes, kinds in canonical order, unknown kinds dropped", () => {
    const r = presetRequest("duration", { minutes: "90", kinds: ["system", "display", "bogus", "display"] })
    expect(r.ok && r.params).toEqual({ kinds: ["display", "system"], reason: "cmux Caffeinate: For 1 hour 30 minutes", timeout_s: 5400 })
  })

  test("duration limits: at least 1 minute, at most 24 hours, a number", () => {
    expect(presetRequest("duration", { minutes: 0 })).toMatchObject({ ok: false, code: "caffeinate.bad_duration" })
    expect(presetRequest("duration", { minutes: 1441 })).toMatchObject({ ok: false, code: "caffeinate.bad_duration" })
    expect(presetRequest("duration", { minutes: "soon" })).toMatchObject({ ok: false, code: "caffeinate.no_duration" })
    expect(presetRequest("duration", { minutes: 1440 }).ok).toBe(true)
  })

  test("while a command runs: Mac only, bound to the terminal's command", () => {
    const r = presetRequest("command", { terminal: "terminal_7", label: "make · api" })
    expect(r.ok && r.params).toEqual({ kinds: ["idle"], reason: "cmux Caffeinate: While make · api runs", until: { terminal: "terminal_7", end: "command" }, until_label: "make · api" })
  })

  test("a terminal handle wins over a task and a raw pid; a pid alone works", () => {
    const both = presetRequest("command", { terminal: "terminal_7", task: "task_2", pid: 4242 })
    expect(both.ok && both.params.until).toEqual({ terminal: "terminal_7", end: "command" })
    const task = presetRequest("command", { task: "task_2", pid: 4242 })
    expect(task.ok && task.params.until).toEqual({ task: "task_2" })
    const pid = presetRequest("command", { pid: "4242" })
    expect(pid.ok && pid.params.until).toEqual({ pid: 4242 })
    expect(pid.ok && pid.params.reason).toBe("cmux Caffeinate: While process 4242 runs")
  })

  test("a command preset needs a handle; strings that are not handles do not count", () => {
    expect(presetRequest("command")).toMatchObject({ ok: false, code: "caffeinate.no_handle" })
    expect(presetRequest("command", { terminal: "api", pid: -3 })).toMatchObject({ ok: false, code: "caffeinate.no_handle" })
  })

  test("a command preset may also carry a time limit (caffeinate -w with -t)", () => {
    const r = presetRequest("command", { terminal: "terminal_7", minutes: 30 })
    expect(r.ok && r.params.timeout_s).toBe(1800)
  })

  test("user activity alone without a time lasts 5 s, as caffeinate -u", () => {
    const r = presetRequest("untilStopped", { kinds: ["user"] })
    expect(r.ok && r.params.timeout_s).toBe(5)
    const timed = presetRequest("duration", { kinds: ["user"], minutes: 10 })
    expect(timed.ok && timed.params.timeout_s).toBe(600)
    const mixed = presetRequest("untilStopped", { kinds: ["user", "display"] })
    expect(mixed.ok && mixed.params.timeout_s).toBeUndefined()
  })

  test("no kinds is refused; a custom reason is kept and trimmed", () => {
    expect(presetRequest("hour", { kinds: [] })).toMatchObject({ ok: false, code: "caffeinate.no_kinds" })
    const r = presetRequest("hour", { reason: "  render video  " })
    expect(r.ok && r.params.reason).toBe("render video")
  })

  test("Japanese text", () => {
    setLanguage("ja-JP")
    const r = presetRequest("duration", { minutes: 90 })
    expect(r.ok && r.params.reason).toBe("cmux カフェイネート: 1時間30分")
  })
})

describe("time left", () => {
  test("rounded up: seconds in the last minute, minutes, hours", () => {
    expect(timeLeftText(0)).toBe("0s")
    expect(timeLeftText(450)).toBe("1s")
    expect(timeLeftText(45_000)).toBe("45s")
    expect(timeLeftText(60_000)).toBe("60s")
    expect(timeLeftText(60_001)).toBe("2m")
    expect(timeLeftText(41 * MIN + 1)).toBe("42m")
    expect(timeLeftText(60 * MIN)).toBe("1h")
    expect(timeLeftText(64 * MIN + 30_000)).toBe("1h 5m")
    expect(timeLeftText(8 * 60 * MIN)).toBe("8h")
    setLanguage("ja")
    expect(timeLeftText(64 * MIN + 30_000)).toBe("1時間5分")
  })

  test("the next text change is the next minute (or second) boundary of the remaining time", () => {
    const end = NOW + 41 * MIN + 30_000 // "42m"
    const next = nextChangeFor(end, NOW)!
    expect(next).toBe(NOW + 30_000)
    expect(timeLeftText(end - next)).toBe("41m")
    expect(timeLeftText(end - (next - 1))).toBe("42m")
    const last = NOW + 1500 // "2s"
    expect(nextChangeFor(last, NOW)).toBe(NOW + 500)
    expect(nextChangeFor(NOW - 1, NOW)).toBeNull()
    expect(nextTextChange([NOW + 10 * MIN, NOW + 45_000, NOW - 5], NOW)).toBe(NOW + 1000)
    expect(nextTextChange([], NOW)).toBeNull()
  })

  test("titles and details", () => {
    const hour = normalizeAssertion(hourAssertion(NOW))!
    expect(assertionTitle(hour)).toBe("For 1 hour")
    expect(assertionDetail(hour, NOW)).toBe("Display, Mac · 42m left")
    const build = normalizeAssertion(commandAssertion(NOW))!
    expect(assertionTitle(build)).toBe("While make · api runs")
    const open = normalizeAssertion(stoppedAssertion(NOW))!
    expect(assertionTitle(open)).toBe("Until stopped")
    expect(assertionDetail(open, NOW)).toBe("Display, Mac, Mac on AC power · Mac on AC power paused on battery")
    const agent = normalizeAssertion(commandAssertion(NOW, { actor: "agent:a1", origin: "agent" }))!
    expect(assertionDetail(agent, NOW)).toBe("Mac · by an agent")
  })
})

describe("state from list and watch events", () => {
  const list = () => fromList(listValue(NOW, [stoppedAssertion(NOW), hourAssertion(NOW), commandAssertion(NOW)]))

  test("the list sorts soonest end first; untimed ones newest first", () => {
    const s = list()
    expect(s.revision).toBe(10n)
    expect(s.assertions.map((a) => a.id)).toEqual(["pwr_01hour", "pwr_02build", "pwr_03open"])
    expect(s.powerSource).toBe("ac")
    expect(soonestEnd(s.assertions)).toBe(NOW + 42 * MIN)
  })

  test("malformed records are dropped", () => {
    const s = fromList({ revision: "1", assertions: [{ assertion: "pwr_x", kinds: [] }, { kinds: ["idle"] }, null, hourAssertion(NOW)] })
    expect(s.assertions.map((a) => a.id)).toEqual(["pwr_01hour"])
  })

  test("created, released (with cause), power, reset; older revisions are ignored", () => {
    let s = list()
    const made = { ...hourAssertion(NOW, { id: "pwr_04", leftMin: 5 }) }
    s = applyEvent(s, { type: "created", revision: "11", assertion: made }, assertionTitle)
    expect(s.assertions[0]!.id).toBe("pwr_04")
    // A replayed or stale event changes nothing.
    const same = applyEvent(s, { type: "released", revision: "11", assertion: "pwr_04", cause: "user" })
    expect(same).toBe(s)
    expect(applyEvent(s, { type: "released", revision: "9", assertion: "pwr_04" })).toBe(s)
    // The user stopped it: no notice.
    s = applyEvent(s, { type: "released", revision: "12", assertion: "pwr_04", cause: "user" }, assertionTitle)
    expect(s.assertions.some((a) => a.id === "pwr_04")).toBe(false)
    expect(s.lastRelease).toBeNull()
    // The command finished: a notice names it.
    s = applyEvent(s, { type: "released", revision: "13", assertion: "pwr_02build", cause: "until" }, assertionTitle)
    expect(s.lastRelease).toEqual({ id: "pwr_02build", cause: "until", title: "While make · api runs" })
    // Unplugged: the system kind pauses.
    s = applyEvent(s, { type: "power", revision: "14", power_source: "battery", inactive: [{ assertion: "pwr_03open", kinds: ["system"] }] })
    expect(s.powerSource).toBe("battery")
    expect(s.assertions.find((a) => a.id === "pwr_03open")!.inactive).toEqual(["system"])
    expect(s.assertions.find((a) => a.id === "pwr_01hour")!.inactive).toEqual([])
    // After a reconnect the host sends the whole state.
    s = applyEvent(s, { type: "reset", revision: "20", available: true, power_source: "ac", assertions: [hourAssertion(NOW)] })
    expect(s.revision).toBe(20n)
    expect(s.assertions.map((a) => a.id)).toEqual(["pwr_01hour"])
    // Revisions compare as integers, not strings.
    s = applyEvent(s, { type: "created", revision: "100", assertion: commandAssertion(NOW) })
    expect(s.revision).toBe(100n)
  })

  test("events without a revision are ignored; the host can become unavailable", () => {
    const s = list()
    expect(applyEvent(s, { type: "created", assertion: hourAssertion(NOW, { id: "pwr_9" }) })).toBe(s)
    const off = applyEvent(s, { type: "power", revision: "11", available: false })
    expect(off.available).toBe(false)
    const empty = fromList({ revision: "3", available: false, unavailable_reason: "power.unsupported_platform", assertions: [] }, emptyState())
    expect(empty.available).toBe(false)
    expect(empty.unavailableReason).toBe("power.unsupported_platform")
  })

  test("running hides assertions whose time is up before the release event arrives", () => {
    const s = fromList(listValue(NOW, [hourAssertion(NOW, { leftMin: 1 }), stoppedAssertion(NOW)]))
    expect(running(s, NOW).length).toBe(2)
    expect(running(s, NOW + 2 * MIN).map((a) => a.id)).toEqual(["pwr_03open"])
  })
})

describe("policy", () => {
  const params = (until?: unknown) => ({ kinds: ["idle" as const], reason: "r", ...(until ? { until } : {}) }) as Parameters<typeof checkCreate>[1]
  const agent = { actor: "agent:a1", origin: "agent" as const, terminal: "terminal_7" }

  test("people may start anything", () => {
    expect(checkCreate({ actor: "user:local", origin: "user" }, params())).toBeNull()
    expect(checkCreate(null, params())).toBeNull()
  })

  test("agents only bind to their own terminal", () => {
    expect(checkCreate(agent, params({ terminal: "terminal_7", end: "command" }))).toBeNull()
    expect(checkCreate(agent, params({ terminal: "terminal_8", end: "command" }))?.code).toBe("power.not_permitted")
    expect(checkCreate(agent, params())?.code).toBe("power.not_permitted")
    expect(checkCreate(agent, params({ pid: 4242 }))?.code).toBe("power.not_permitted")
    expect(checkCreate(agent, { ...params({ terminal: "terminal_7", end: "command" }), timeout_s: 4 * 3600 })).toBeNull()
    expect(checkCreate(agent, { ...params({ terminal: "terminal_7", end: "command" }), timeout_s: 4 * 3600 + 1 })?.code).toBe("power.not_permitted")
    expect(checkCreate({ ...agent, terminal: null }, params({ terminal: "terminal_7", end: "command" }))?.code).toBe("power.not_permitted")
  })

  test("stopping someone else's assertion needs a person", () => {
    const mine = normalizeAssertion(commandAssertion(NOW, { actor: "agent:a1", origin: "agent" })) as Assertion
    const theirs = normalizeAssertion(hourAssertion(NOW)) as Assertion
    expect(checkRelease(agent, mine)).toBeNull()
    expect(checkRelease(agent, theirs)?.code).toBe("power.not_permitted")
    expect(checkRelease({ actor: "user:local", origin: "user" }, mine)).toBeNull()
  })

  test("invoker from the proposed command context", () => {
    expect(invokerOf(undefined)).toBeNull()
    expect(invokerOf({ invoker: { actor: "agent:a1", origin: "agent", terminal: "terminal_7" } })).toEqual(agent)
    expect(invokerOf({ invoker: { actor: "x", origin: "weird" } })).toEqual({ actor: "x", origin: "script", terminal: null })
  })
})

describe("running commands", () => {
  test("a shell at its prompt is not a running command", () => {
    expect(busyLabel("/usr/bin/make", "api")).toBe("make · api")
    expect(busyLabel("/bin/zsh", "api")).toBeNull()
    expect(busyLabel("-bash", "api")).toBeNull()
    expect(busyLabel(null, "api")).toBeNull()
    expect(busyLabel("/opt/tools/bin/bun", "bun")).toBe("bun")
  })
})
