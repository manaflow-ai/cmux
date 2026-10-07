import { describe, expect, test } from "bun:test"
import { STEPS, fraction, initialProgress, nextOpen, parseProgress, reduce, remaining, shouldShow, stepState, type Facts, type OnboardingEvent, type Progress } from "../src/onboarding.ts"

const team: Facts = { signedIn: true, scopeKind: "team", connected: 0, privateConnected: 0, agentsRouted: false, keys: 0, lastTestOk: false }
const personal: Facts = { ...team, scopeKind: "personal" }

const run = (events: OnboardingEvent[], f: Facts, start: Progress = initialProgress()) => events.reduce((p, e) => reduce(p, e, f, 1), start)

describe("onboarding", () => {
  test("Continue walks every step and finishes", () => {
    let p = initialProgress()
    const seen: string[] = []
    while (!p.finished) {
      seen.push(p.current)
      p = reduce(p, { type: "next" }, team, 1)
    }
    expect(seen).toEqual([...STEPS])
    expect(p.done).toEqual([...STEPS])
  })

  test("a personal scope never visits the share step", () => {
    const p = run([{ type: "next" }, { type: "next" }], personal)
    expect(p.current).toBe("use")
    expect(stepState("share", p, personal)).toBe("notNeeded")
    expect(run([{ type: "back" }], personal, p).current).toBe("connect")
  })

  test("data completes steps without clicks", () => {
    const f: Facts = { ...team, connected: 2, privateConnected: 0, keys: 1, lastTestOk: true }
    const p = initialProgress()
    expect(stepState("connect", p, f)).toBe("done")
    expect(stepState("share", p, f)).toBe("done")
    expect(stepState("use", p, f)).toBe("done")
    expect(nextOpen(p, f)).toBe("detect")
    expect(reduce(p, { type: "next" }, f, 1).finished).toBe(true)
  })

  test("skip settles a step, restart reopens skipped steps", () => {
    const p = run([{ type: "skip" }, { type: "skip" }], team)
    expect(p.current).toBe("share")
    expect(p.skipped).toEqual(["detect", "connect"])
    expect(remaining(p, team)).toBe(3)
    const again = reduce(p, { type: "restart" }, team, 2)
    expect(again.current).toBe("detect")
    expect(again.skipped).toEqual([])
  })

  test("dismiss hides setup; goto reopens it", () => {
    const p = run([{ type: "dismiss" }], team)
    expect(shouldShow(p, team)).toBe(false)
    expect(shouldShow(reduce(p, { type: "goto", step: "test" }, team, 2), team)).toBe(true)
    expect(shouldShow(initialProgress(), { ...team, signedIn: false })).toBe(false)
  })

  test("complete on another step keeps the current one", () => {
    const p = run([{ type: "complete", step: "test" }], team)
    expect(p.current).toBe("detect")
    expect(p.done).toEqual(["test"])
    expect(fraction(p, team)).toBeCloseTo(1 / 5)
    expect(fraction(p, personal)).toBeCloseTo(1 / 4)
  })

  test("storage round trip and garbage", () => {
    const p = run([{ type: "next" }, { type: "skip" }], team)
    expect(parseProgress(JSON.parse(JSON.stringify(p)))).toEqual(p)
    expect(parseProgress(null)).toEqual(initialProgress())
    expect(parseProgress({ version: 2 })).toEqual(initialProgress())
    expect(parseProgress({ version: 1, current: "nope", done: ["detect", "bogus"] }).done).toEqual(["detect"])
  })

  test("any event sequence keeps the current step valid and lists without duplicates", () => {
    const events: OnboardingEvent[] = [{ type: "next" }, { type: "back" }, { type: "skip" }, { type: "dismiss" }, { type: "restart" }, ...STEPS.map((step) => ({ type: "goto", step }) as const), ...STEPS.map((step) => ({ type: "complete", step }) as const)]
    let seed = 7
    const rand = () => (seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31
    for (let trial = 0; trial < 300; trial++) {
      const f = rand() < 0.5 ? team : { ...personal, connected: Math.floor(rand() * 3) }
      let p = initialProgress()
      for (let i = 0; i < 25; i++) {
        p = reduce(p, events[Math.floor(rand() * events.length)]!, f, i)
        expect(STEPS).toContain(p.current)
        expect(new Set(p.done).size).toBe(p.done.length)
        expect(new Set(p.skipped).size).toBe(p.skipped.length)
        expect(p.done.some((s) => p.skipped.includes(s))).toBe(false)
      }
    }
  })
})
