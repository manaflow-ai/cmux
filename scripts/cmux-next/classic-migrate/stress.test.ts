import { describe, expect, test } from "bun:test"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { apply, rollback } from "./apply.ts"
import { HttpError, mapTenantResolver, type PlatformImports, type VmApiImports } from "./clients.ts"
import { Ledger } from "./ledger.ts"
import { buildPlan, copiesOf } from "./plan.ts"
import { fixtureSource, readFixture } from "./source.ts"

// No soak: break apply and rollback fast and repeatedly instead (Leo, 2026-11-10: "I hate soaks ... You should
// synthetically just break it fast and repeatedly"). Each seed runs a random sequence of apply and rollback
// passes against in-memory NEXT fakes that fail before or after their side effect (a lost answer), then checks
// the invariants: never two live copies of one classic VM, and a final clean rollback leaves nothing behind.

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

/** In-memory NEXT: both surfaces idempotent on (migration, classic VM), the way the real routes are specified. */
const fakeNext = (fault: () => Fault) => {
  // Every snapshot ever made stays listed, so a lost one (a leak) is still counted.
  const snaps: { key: string; id: string; live: boolean }[] = []
  const machines = new Map<string, { snap: string; live: boolean }>()
  let snapSeq = 0
  const hit = async <T>(effect: () => T): Promise<T> => {
    const f = fault()
    if (f === "before") throw new Error("connection reset (before the side effect)")
    if (f === "refused") throw new HttpError(503, "busy", "")
    const out = effect()
    if (f === "after") throw new Error("timeout (after the side effect: the answer was lost)")
    return out
  }
  const vmApi: VmApiImports = {
    importSnapshot: (req) =>
      hit(() => {
        const key = `${req.tenant_id}|${req.classic_vm_id}|${req.migration_id}`
        let s = snaps.find((x) => x.key === key && x.live)
        if (!s) {
          s = { key, id: `snap_${String(++snapSeq).padStart(26, "0")}`, live: true }
          snaps.push(s)
        }
        return { id: s.id }
      }),
    deleteSnapshot: (id) =>
      hit(() => {
        for (const s of snaps) if (s.id === id) s.live = false
      }),
  }
  const platform: PlatformImports = {
    importMachine: (req) =>
      hit(() => {
        const key = `${req.team}|${req.classic_vm_id}|${req.migration_id}`
        const live = snaps.some((s) => s.id === req.vm_api_snapshot_id && s.live)
        if (!live) throw new HttpError(404, "snapshot gone", "")
        const m = machines.get(key)
        if (!m || !m.live) machines.set(key, { snap: req.vm_api_snapshot_id, live: true })
        return { machine: key, snapshot: req.vm_api_snapshot_id }
      }),
    deleteMachine: (req) =>
      hit(() => {
        const m = machines.get(`${req.team}|${req.classic_vm_id}|${req.migration_id}`)
        if (m) m.live = false
      }),
  }
  const liveSnaps = () => snaps.filter((s) => s.live).length
  const liveMachines = () => [...machines.values()].filter((m) => m.live)
  return { vmApi, platform, liveSnaps, liveMachines }
}

describe("apply and rollback under injected faults", () => {
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
        const tenants = mapTenantResolver({ [ALICE]: "tenant_alice_personal" })
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
          const deps = { vmApi: next.vmApi, platform: next.platform, resolvePersonalTenant: tenants }
          let rolled = false
          for (let pass = 0, passes = 1 + Math.floor(r() * 6); pass < passes; pass++) {
            if (!rolled && r() < 0.85) await apply(plan, ledger, deps)
            else {
              await rollback(ledger, deps)
              rolled = true
            }
            // Never two live machines, or more snapshots than VMs, for one classic VM.
            expect(next.liveMachines().length).toBeLessThanOrEqual(copies)
            expect(next.liveSnaps()).toBeLessThanOrEqual(copies)
          }
          // Faults clear: apply (if not rolled back) finishes every copy, and a clean rollback empties NEXT.
          faulty = false
          if (!rolled) {
            const report = await apply(plan, ledger, deps)
            expect({ seed, failed: report.failed }).toEqual({ seed, failed: [] })
            expect(next.liveMachines().length).toBe(copies)
          }
          const back = await rollback(ledger, deps)
          expect({ seed, failed: back.failed }).toEqual({ seed, failed: [] })
          expect({ seed, machines: next.liveMachines().length, snaps: next.liveSnaps() }).toEqual({ seed, machines: 0, snaps: 0 })
          // A second rollback sends nothing that changes state.
          expect((await rollback(ledger, deps)).failed).toEqual([])
        }
      } finally {
        rmSync(dir, { recursive: true, force: true })
      }
    })
  }
})
