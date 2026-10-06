import { describe, expect, test } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { initialNavState, invariantViolations, NavReducer, navConfig, runVector, type NavEvent, type NavRow, type NavState, type VectorCase } from "../src/index.ts"
import { graphOf } from "../src/vectors.ts"

const doc = JSON.parse(readFileSync(join(import.meta.dir, "../palette-nav-vectors.json"), "utf8")) as { format: number; cases: VectorCase[] }

describe("palette-nav-vectors.json", () => {
  test("has at least 25 uniquely named cases", () => {
    expect(doc.format).toBe(1)
    expect(doc.cases.length).toBeGreaterThanOrEqual(25)
    expect(new Set(doc.cases.map((c) => c.name)).size).toBe(doc.cases.length)
  })
  test("covers every rule of palette-scopes.md section 4.3", () => {
    const rules = doc.cases.flatMap((c) => (c.rule ?? "").split(" "))
    for (let i = 1; i <= 10; i++) expect(rules).toContain(`4.3.${i}`)
  })
  for (const c of doc.cases) {
    test(c.name, () => {
      const { actual, expected } = runVector(c)
      for (const key of Object.keys(actual)) expect({ [key]: actual[key] }).toEqual({ [key]: expected[key] })
    })
  }
})

// The seeded property run of PaletteNavPropertyTests, on the TypeScript port.
describe("invariants under random sequences", () => {
  const base = doc.cases[0]!
  const graph = graphOf(base)
  const scopes = [...graph.order, "missing"]
  const queries = ["", "a", "ab", "@", "#x", ">", "?", "!", "tabs", "Notes ", "x@", ",", "closed"]

  function mulberry(seed: number) {
    return () => {
      seed |= 0
      seed = (seed + 0x6d2b79f5) | 0
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296
    }
  }

  const run = (seed: number) => {
    const rnd = mulberry(seed)
    const pick = <T>(xs: readonly T[]) => xs[Math.floor(rnd() * xs.length)]!
    const int = (lo: number, hi: number) => lo + Math.floor(rnd() * (hi - lo + 1))
    const config = navConfig({ maxDepth: 3 + (seed % 4) })
    const reducer = new NavReducer(graph, config)
    const state: NavState = initialNavState()
    const pending: Array<{ levelID: number; scope: string; generation: number }> = []
    const history: Array<{ levelID: number; generation: number }> = []
    const rows = (): NavRow[] =>
      Array.from({ length: int(0, 5) }, () => {
        const roll = int(0, 5)
        return { id: pick(["r0", "r1", "r2", "r3", "r4", "r5"]), enters: roll === 0 ? pick(scopes) : null, drills: roll === 1 || roll === 2 ? "actions" : roll === 3 ? pick(scopes) : null, isEnabled: int(0, 7) !== 0 }
      })
    const event = (): NavEvent => {
      const roll = int(0, 99)
      if (roll < 4) return { event: "open", scope: pick([null, "root", "tabs", "workspaces", "app:cmux/notes#notes", "closed", "missing"]), query: pick(queries) }
      if (roll < 6) return { event: "close" }
      if (roll < 24) return { event: "setQuery", text: pick(queries) }
      if (roll < 32) return { event: "backspaceOnEmpty" }
      if (roll < 40) return { event: "tab" }
      if (roll < 43) return { event: "shiftTab" }
      if (roll < 48) return { event: "escape" }
      if (roll < 51) return { event: "popTo", index: int(-1, 6) }
      if (roll < 56) return { event: "activate", rowID: rnd() < 0.5 ? null : pick(["r0", "r1", "r2", "zz"]) }
      if (roll < 62) return { event: "move", delta: int(-3, 3) }
      if (roll < 64) return { event: "select", rowID: pick(["r0", "r1", "r2", "zz"]) }
      if (roll < 66) return { event: "refresh" }
      if (roll < 67) return { event: "push", scope: pick(["page.rename", "page.pick"]), row: rnd() < 0.5 ? "r0" : null }
      if (roll < 90 && pending.length) {
        const p = pending.splice(int(0, pending.length - 1), 1)[0]!
        return { event: "results", levelID: p.levelID, generation: p.generation, rows: rows(), replace: rnd() < 0.7, isFinal: rnd() < 0.8 }
      }
      const h = history.length ? pick(history) : { levelID: 1, generation: 1 }
      return { event: "results", levelID: h.levelID, generation: h.generation, rows: rows(), replace: true, isFinal: true }
    }
    for (let step = 0; step < 60; step++) {
      const e = event()
      const before = JSON.stringify(state)
      const effects = reducer.reduce(state, e)
      for (const fx of effects) {
        if (fx.effect !== "load") continue
        // I6: every load names a live level and its current generation.
        const level = state.levels.find((l) => l.id === fx.levelID)
        expect(level?.generation).toBe(fx.generation)
        pending.push({ levelID: fx.levelID, scope: fx.scope, generation: fx.generation })
        history.push({ levelID: fx.levelID, generation: fx.generation })
      }
      // P3: a batch for a stale generation or a gone level changes nothing.
      if (e.event === "results") {
        const level = JSON.parse(before).levels.find((l: { id: number }) => l.id === e.levelID)
        if (!level || level.generation !== e.generation) {
          expect(effects).toEqual([])
          expect(JSON.stringify(state)).toBe(before)
        }
      }
      expect(invariantViolations(state, config.maxDepth)).toEqual([])
    }
    // P4: at most depth + 2 Escapes close the palette.
    if (state.isOpen) {
      const limit = state.levels.length + 2
      for (let i = 0; i < limit && state.isOpen; i++) reducer.reduce(state, { event: "escape" })
      expect(state.isOpen).toBe(false)
    }
  }

  test("500 seeds of 60 events keep I1 to I6, P3 and P4", () => {
    for (let seed = 1; seed <= 500; seed++) run(seed)
  })
})
