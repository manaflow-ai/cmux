import { describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { apply, rollback, verify } from "./apply.ts"
import { HttpError, type PlatformImports } from "./clients.ts"
import { Ledger } from "./ledger.ts"
import { buildPlan, copiesOf } from "./plan.ts"
import { fixtureSource, readFixture } from "./source.ts"

// No soak: break apply and rollback fast and repeatedly instead (Leo, 2026-11-10: "I hate soaks ... You should
// synthetically just break it fast and repeatedly"). Each seed runs a random sequence of apply and rollback
// passes, and `apply --fresh` re-migrations after a rollback, against an in-memory platform route that fails before
// or after its side effect (a lost answer), then checks the invariants: never two live copies of one classic VM
// across all attempts, a clean apply verifies, and a final clean rollback leaves nothing behind.

const PROJECT = "00000000-0000-4000-8000-0000000057a6"
const ALICE = "11111111-1111-4111-8111-111111111111"
const ACME = "bbbbbbbb-0000-4000-8000-000000000ac3"
const SEEDS = 300

/** mulberry32: a small seeded PRNG, so a failing seed replays exactly. */
const rng = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

type Fault = "none" | "before" | "after" | "refused"

/**
 * In-memory cmux-platform migration route: idempotent on (team, migration, classic VM) the way
 * ClassicMigrationRoute.ts is. A POST makes the VM API import and the machine together; a DELETE removes both, and
 * a cut-off POST's import too (the platform lists imports by migration and classic VM).
 */
const fakeNext = (fault: () => Fault) => {
  const machines = new Map<string, { id: string; live: boolean }>()
  // Every import ever made stays listed, so a lost one (a leak) is still counted.
  const imports = new Map<string, boolean>()
  let seq = 0
  const hit = async <T>(effect: () => T): Promise<T> => {
    const f = fault()
    if (f === "before") throw new Error("connection reset (before the side effect)")
    if (f === "refused") throw new HttpError(503, "busy", "")
    const out = effect()
    if (f === "after") throw new Error("timeout (after the side effect: the answer was lost)")
    return out
  }
  const platform: PlatformImports = {
    importMachine: (req) =>
      hit(() => {
        const key = `${req.team}|${req.migration_id}|${req.classic_vm_id}`
        imports.set(key, true)
        const m = machines.get(key)
        if (m?.live) return { status: "existing", machine: m.id, snapshot: null, vm_api_snapshot_id: null }
        const id = `mach_${++seq}`
        machines.set(key, { id, live: true })
        return { status: "created", machine: id, snapshot: null, vm_api_snapshot_id: null }
      }),
    deleteMachine: (req) =>
      hit(() => {
        const key = `${req.team}|${req.migration_id}|${req.classic_vm_id}`
        const m = machines.get(key)
        const had = (m?.live ?? false) || imports.get(key) === true
        if (m) m.live = false
        imports.set(key, false)
        return had ? "deleted" : "absent"
      }),
    list: (team, migration) =>
      hit(() =>
        [...machines]
          .filter(([k, m]) => m.live && k.startsWith(`${team}|${migration}|`))
          .map(([k, m]) => ({
            classic_vm_id: k.split("|")[2]!,
            status: "created",
            machine: { id: m.id, status: "running" },
            snapshot: null,
          })),
      ),
  }
  /** Live machines per classic VM across every attempt (one migration, so the VM id is the last key part). */
  const livePerVm = () => {
    const n = new Map<string, number>()
    for (const [k, m] of machines) if (m.live) n.set(k.split("|")[2]!, (n.get(k.split("|")[2]!) ?? 0) + 1)
    return [...n.values()]
  }
  const liveMachines = () => [...machines.values()].filter((m) => m.live).length
  const liveImports = () => [...imports.values()].filter(Boolean).length
  return { platform, livePerVm, liveMachines, liveImports }
}

describe("apply, rollback and fresh re-migration under injected faults", () => {
  for (const subject of [
    { kind: "user" as const, id: ALICE },
    { kind: "team" as const, id: ACME },
  ]) {
    test(`${subject.kind}: ${SEEDS} seeded runs keep one copy at most and roll back to nothing`, async () => {
      const dir = mkdtempSync(join(tmpdir(), "classic-migrate-stress-"))
      try {
        const plan = buildPlan(await fixtureSource(readFixture(join(import.meta.dirname, "fixtures/staging-test.json")), "fixture").read(subject), PROJECT, "fixture")
        const copies = copiesOf(plan).length
        expect(copies).toBeGreaterThan(0)
        let freshRuns = 0
        for (let seed = 1; seed <= SEEDS; seed++) {
          const r = rng(seed)
          let faulty = true
          const fault = (): Fault => {
            if (!faulty) return "none"
            const x = r()
            return x < 0.15 ? "before" : x < 0.3 ? "after" : x < 0.4 ? "refused" : "none"
          }
          const next = fakeNext(fault)
          const ledger = new Ledger(join(dir, `seed-${seed}.jsonl`))
          const deps = { platform: next.platform }
          for (let pass = 0, passes = 1 + Math.floor(r() * 8); pass < passes; pass++) {
            const x = r()
            if (x < 0.55) await apply(plan, ledger, deps)
            else if (x < 0.8) await rollback(ledger, deps)
            else {
              // A re-migration: refused while the current attempt still holds something, else a new attempt.
              try {
                await apply(plan, ledger, deps, { fresh: true })
                freshRuns++
              } catch (e) {
                expect(String(e)).toContain("run rollback first")
              }
            }
            // Never two live machines for one classic VM, whatever the attempt.
            for (const n of next.livePerVm()) expect({ seed, n }).toEqual({ seed, n: 1 })
          }
          // Faults clear: rollback, a fresh attempt finishes every copy and verifies, and a clean rollback empties NEXT.
          faulty = false
          expect({ seed, failed: (await rollback(ledger, deps)).failed }).toEqual({ seed, failed: [] })
          const report = await apply(plan, ledger, deps, { fresh: true })
          expect({ seed, failed: report.failed }).toEqual({ seed, failed: [] })
          expect(next.liveMachines()).toBe(copies)
          expect({ seed, verify: (await verify(ledger, deps)).ok }).toEqual({ seed, verify: true })
          // Re-applying changes nothing.
          expect((await apply(plan, ledger, deps)).sent).toBe(0)
          const back = await rollback(ledger, deps)
          expect({ seed, failed: back.failed }).toEqual({ seed, failed: [] })
          expect({ seed, machines: next.liveMachines(), imports: next.liveImports() }).toEqual({ seed, machines: 0, imports: 0 })
          expect({ seed, verify: (await verify(ledger, deps)).ok }).toEqual({ seed, verify: true })
          // A second rollback sends nothing.
          expect((await rollback(ledger, deps)).sent).toBe(0)
        }
        expect(freshRuns).toBeGreaterThan(10)
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })
  }
})
