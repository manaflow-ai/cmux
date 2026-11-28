/// <reference types="@cloudflare/vitest-pool-workers/types" />
/**
 * Bench: the tenant ledger's per-call scans against real Durable Object storage (workerd SQLite), old code
 * (test/support/ledger-scan-legacy.ts) and new side by side in one harness, at 100 and 1,000 retained slots / agent
 * slots per tenant. Prints one `LEDGER_SCAN_BENCH` JSON line per (op, n, impl): wall p50/p95 in ms and storage calls
 * per op. Budgets fail the run when the new code's storage calls stop being bounded.
 */
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { expect, it } from "vitest";
import { forgetAgentVm, admitAgentSlot } from "../../src/limits/agent-slots.ts";
import { TenantLedger, type LedgerStorage } from "../../src/limits/ledger.ts";
import { newVmId } from "../../src/lib/ids.ts";
import { legacyAdmitAgentSlot, legacyForgetAgentVm, legacyReserve, legacyRetainedCreations } from "../support/ledger-scan-legacy.ts";

type Calls = { get: number; put: number; delete: number; list: number; rows: number };
const counted = (store: DurableObjectStorage | DurableObjectTransaction, calls: Calls): LedgerStorage => ({
  get: (key) => { calls.get += 1; return store.get(key); },
  getMany: (keys) => { calls.get += 1; return store.get([...keys]); },
  put: (key, value) => { calls.put += 1; return store.put(key, value); },
  delete: (key) => { calls.delete += 1; return store.delete(key); },
  deleteMany: (keys) => { calls.delete += 1; return store.delete([...keys]); },
  list: async (options) => { calls.list += 1; const rows = await store.list(options); calls.rows += rows.size; return rows; },
  transaction: (run) => "transaction" in store ? store.transaction((tx) => run(counted(tx, calls))) : run(counted(store, calls)),
});

const quantile = (sorted: number[], q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;

const seed = async (storage: DurableObjectStorage, n: number, now: number) => {
  const rows: Record<string, unknown> = {};
  for (let i = 0; i < n; i += 1) {
    const vmId = newVmId(), key = `create-${i}`, reservationId = `slot-${i}`, createdAt = new Date(now - i * 1000).toISOString();
    rows[`reserve:${reservationId}`] = { kind: "vm", expiresMs: now - 1, retained: true, vmCreation: { key, vmId } };
    rows[`idem:${key}`] = { fingerprint: "f", leaseUntilMs: 0, expiresMs: now + 3_600_000, progress: {
      phase: "creating", vmId, reservationId, context: "c", createdBy: i % 2 === 0 ? "ci:a" : "ci:b",
      intent: { receipt: { id: vmId, displayName: null, labels: {}, idleTimeoutSeconds: 300 }, probe: { provider: "p", environment: "e", request: "r" }, createdAt, floors: {} },
      dispatch: { state: "sent", token: "t", at: now - i * 1000 } } };
    rows[`agentslot:key:ak_${i % Math.max(1, n / 10)}:s${i}`] = { expiresMs: now + 3_600_000, vmId };
  }
  const entries = Object.entries(rows);
  for (let i = 0; i < entries.length; i += 128) await storage.put(Object.fromEntries(entries.slice(i, i + 128)));
};

const ITERATIONS = 15;

// This bench runs in cmux-vm.yml's deploy-gating `check` step, so a workerd fault in it holds a Cloud deploy back:
// run 46095847624 (feat-cmux-next @eb534854) went red only on `Error: internal error; reference = g0a8hkb3ouu9qftqd71c2k70`
// thrown by the seed's `storage.put`, before any budget ran. Its budgets count storage calls, which are deterministic,
// so a retry cannot pass a real regression: a too-many-calls build fails every attempt. Fresh DO ids per attempt.
it("bounds the ledger's per-call storage work at 100 and 1,000 slots (old vs new, one harness)", { retry: 2, timeout: 180_000 }, async () => {
  const report: Record<string, { p50: number; p95: number; calls: Calls }> = {};
  for (const n of [100, 1_000]) {
    const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(`ledger-scan-bench-${n}-${crypto.randomUUID()}`));
    await runInDurableObject(stub, async (_instance, state) => {
      const now = Date.now();
      await seed(state.storage, n, now);
      const ops: Record<string, Record<"old" | "new", (s: LedgerStorage, i: number) => Promise<unknown>>> = {
        reserve: {
          old: async (s, i) => { await legacyReserve(s, "vm", 1_000_000, 0, now, `bench-${i}`); },
          new: async (s, i) => { await new TenantLedger(s).reserve("vm", 1_000_000, 0, now, `bench-${i}`); },
        },
        retainedCreations: {
          old: (s) => legacyRetainedCreations(s, "ci:a", 64),
          new: (s) => new TenantLedger(s).retainedCreations("ci:a", 64),
        },
        admitAgentSlot: {
          old: (s, i) => legacyAdmitAgentSlot(s, "key:ak_0", 1_000_000, [], now, `bench-${i}`),
          new: (s, i) => admitAgentSlot(s, "key:ak_0", 1_000_000, [], now, `bench-${i}`),
        },
        forgetAgentVm: {
          old: (s) => legacyForgetAgentVm(s, "vm_absent", null),
          new: (s) => forgetAgentVm(s, "vm_absent", null),
        },
      };
      for (const [op, impls] of Object.entries(ops)) {
        for (const impl of ["old", "new"] as const) {
          const walls: number[] = [], calls: Calls = { get: 0, put: 0, delete: 0, list: 0, rows: 0 };
          for (let i = 0; i < ITERATIONS; i += 1) {
            const s = counted(state.storage, calls), started = performance.now();
            await impls[impl](s, i);
            walls.push(performance.now() - started);
            // Undo the bench's own write so each iteration sees the same n.
            await state.storage.delete([`reserve:bench-${i}`, `agentslot:key:ak_0:bench-${i}`]);
          }
          walls.sort((a, b) => a - b);
          const per: Calls = { get: calls.get / ITERATIONS, put: calls.put / ITERATIONS, delete: calls.delete / ITERATIONS, list: calls.list / ITERATIONS, rows: calls.rows / ITERATIONS };
          report[`${op}/${n}/${impl}`] = { p50: quantile(walls, 0.5), p95: quantile(walls, 0.95), calls: per };
          console.log(`LEDGER_SCAN_BENCH ${JSON.stringify({ op, n, impl, p50Ms: +quantile(walls, 0.5).toFixed(3), p95Ms: +quantile(walls, 0.95).toFixed(3), callsPerOp: per })}`);
        }
      }
    });
  }
  // Expiry: a reserve that finds n lapsed reservations (a tenant whose creates died) deletes them. One call each.
  for (const n of [100, 1_000]) {
    for (const impl of ["old", "new"] as const) {
      const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(`ledger-scan-expiry-${n}-${impl}-${crypto.randomUUID()}`));
      await runInDurableObject(stub, async (_instance, state) => {
        const now = Date.now(), rows: Record<string, unknown> = {};
        for (let i = 0; i < n; i += 1) rows[`reserve:lapsed-${i}`] = { kind: "vm", expiresMs: now - 1 };
        const entries = Object.entries(rows);
        for (let i = 0; i < entries.length; i += 128) await state.storage.put(Object.fromEntries(entries.slice(i, i + 128)));
        const calls: Calls = { get: 0, put: 0, delete: 0, list: 0, rows: 0 }, s = counted(state.storage, calls), started = performance.now();
        if (impl === "old") await legacyReserve(s, "vm", 10, 0, now, "fresh");
        else await new TenantLedger(s).reserve("vm", 10, 0, now, "fresh");
        const wall = performance.now() - started;
        expect((await state.storage.list({ prefix: "reserve:" })).size).toBe(1);
        report[`reserveExpiry/${n}/${impl}`] = { p50: wall, p95: wall, calls };
        console.log(`LEDGER_SCAN_BENCH ${JSON.stringify({ op: "reserveExpiry", n, impl, wallMs: +wall.toFixed(3), callsPerOp: calls })}`);
      });
    }
  }
  // Budgets on the new code (storage calls are what workerd bills and what grows): retainedCreations reads its
  // linked intents in batches of 128, not one get per slot.
  // linked intents in batches of 128, not one get per slot; an expiring reserve deletes lapsed rows the same way.
  // Wall time is logged, not asserted: shared runners are too noisy for a fail-closed wall budget.
  for (const n of [100, 1_000]) {
    expect(report[`retainedCreations/${n}/new`]!.calls.get).toBeLessThanOrEqual(Math.ceil(n / 128));
    expect(report[`reserveExpiry/${n}/new`]!.calls.delete).toBeLessThanOrEqual(Math.ceil(n / 128));
  }
});
