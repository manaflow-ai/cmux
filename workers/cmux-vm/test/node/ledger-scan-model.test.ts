/**
 * Model-based check for the batched ledger scans: the pre-batching code (test/support/ledger-scan-legacy.ts) is the
 * oracle. Seeded random sequences of reserve / release / retain / expire / corrupt / agent-slot ops run against two
 * stores, old code on one and new on the other; every answer and the whole stored state must match after each op.
 * The new side runs twice: with batched storage calls and with a store that has none (the per-key fallback).
 */
import { expect, it } from "vitest";
import { admitAgentSlot, forgetAgentVm, settleAgentSlot } from "../../src/limits/agent-slots.ts";
import { memoryLedgerStorage, TenantLedger, type LedgerStorage } from "../../src/limits/ledger.ts";
import { legacyAdmitAgentSlot, legacyForgetAgentVm, legacyReserve, legacyRetainedCreations } from "../support/ledger-scan-legacy.ts";

const rng = (seed: number) => () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};

const withoutBatches = (view: LedgerStorage): LedgerStorage => ({
  get: (key) => view.get(key), put: (key, value) => view.put(key, value), delete: (key) => view.delete(key),
  list: (options) => view.list(options), transaction: (work) => view.transaction((tx) => work(withoutBatches(tx))),
});

const dump = async (storage: LedgerStorage) => Object.fromEntries(await storage.list({ prefix: "" }));

const run = async (seed: number, batched: boolean) => {
  const random = rng(seed), pick = <T>(xs: ReadonlyArray<T>): T => xs[Math.floor(random() * xs.length)]!;
  const oldStore = memoryLedgerStorage(), rawNew = memoryLedgerStorage(), newStore = batched ? rawNew : withoutBatches(rawNew);
  const ledger = new TenantLedger(newStore);
  const ids = Array.from({ length: 12 }, (_, i) => `r${i}`), vms = Array.from({ length: 8 }, (_, i) => `vm_${i}`);
  const agents = ["key:ak_1", "key:ak_2", "key:ak_3"], creators = ["ci:a", "ci:b"];
  let now = 1_000;
  const both = async (write: (s: LedgerStorage) => Promise<unknown>) => { await write(oldStore); await write(rawNew); };
  for (let step = 0; step < 200; step += 1) {
    const op = pick(["reserve", "reserve", "release", "retain", "expire", "corrupt", "retained", "admitSlot", "admitSlot", "settle", "forget"] as const);
    if (op === "reserve") {
      const kind = pick(["vm", "snapshot"]), limit = 1 + Math.floor(random() * 6), live = Math.floor(random() * 3), id = pick(ids);
      expect(await ledger.reserve(kind, limit, live, now, id)).toEqual(await legacyReserve(oldStore, kind, limit, live, now, id));
    } else if (op === "release") {
      const id = pick(ids);
      await both(async (s) => { await new TenantLedger(s).release(id); });
    } else if (op === "retain") {
      // What advance does to a slot whose create began: retained, optionally linked to its intent.
      const id = pick(ids), key = `k-${id}`, vmId = pick(vms), linked = random() < 0.7, createdBy = pick(creators), kind = pick(["vm", "vm", "snapshot"]);
      const progress = { phase: "creating", vmId, reservationId: id, context: "c", createdBy,
        intent: { receipt: { id: vmId, displayName: null, labels: {}, idleTimeoutSeconds: 300 }, probe: { provider: "p", environment: "e", request: "r" }, createdAt: new Date(now).toISOString(), floors: {} },
        ...(random() < 0.8 ? { dispatch: { state: "sent", token: "t", ...(random() < 0.5 ? { at: now - Math.floor(random() * 50) } : {}) } } : {}),
        ...(random() < 0.3 ? { cancelRequested: true } : {}) };
      await both(async (s) => {
        await s.put(`reserve:${id}`, { kind, expiresMs: now, retained: true, ...(linked ? { vmCreation: { key, vmId } } : {}) });
        await s.put(`idem:${key}`, { fingerprint: "f", leaseUntilMs: 0, expiresMs: now + 10_000, progress });
      });
    } else if (op === "expire") {
      now += Math.floor(random() * 400_000);
    } else if (op === "corrupt") {
      const key = random() < 0.5 ? `reserve:${pick(ids)}` : `agentslot:${pick(agents)}:${pick(ids)}`;
      await both((s) => s.put(key, { garbage: true }));
    } else if (op === "retained") {
      const createdBy = pick(creators), limit = 1 + Math.floor(random() * 5);
      expect(await ledger.retainedCreations(createdBy, limit)).toEqual(await legacyRetainedCreations(oldStore, createdBy, limit));
    } else if (op === "admitSlot") {
      const agent = pick(agents), limit = 1 + Math.floor(random() * 4), owned = vms.filter(() => random() < 0.2), slot = pick(ids);
      expect(await admitAgentSlot(newStore, agent, limit, owned, now, slot)).toBe(await legacyAdmitAgentSlot(oldStore, agent, limit, owned, now, slot));
    } else if (op === "settle") {
      const agent = pick(agents), slot = pick(ids), vmId = pick(vms);
      const outcome = pick([{ recorded: vmId }, { held: `ck-${slot}`, vmId }, "released" as const]);
      await both((s) => settleAgentSlot(s, agent, slot, outcome, now));
    } else {
      const vmId = pick(vms), creationKey = random() < 0.5 ? null : `ck-${pick(ids)}`;
      await forgetAgentVm(newStore, vmId, creationKey);
      await legacyForgetAgentVm(oldStore, vmId, creationKey);
    }
    expect(await dump(rawNew), `seed ${seed} step ${step} (${op})`).toEqual(await dump(oldStore));
  }
};

it("matches the pre-batching ledger scans on 24 seeded random op sequences", async () => {
  for (let seed = 1; seed <= 12; seed += 1) {
    await run(seed, true);
    await run(seed, false);
  }
});
