import { expect, it } from "vitest";
import { memoryLedgerStorage, TenantLedger, type LedgerStorage } from "../../src/limits/ledger.ts";
import { newVmCreationKey, newVmId } from "../../src/lib/ids.ts";

const retained = async (ledger: TenantLedger, n: number, supplied = false) => {
  const id = newVmId(), key = `internal-${n}`, createdAt = new Date(1_800_000_000_000 + n).toISOString();
  const generated = { key: newVmCreationKey(), cursor: n.toString(16).padStart(64, "0"), scope: "tenant", createdBy: "key:owner",
    createdAt, displayName: null, labels: {}, operation: "create" as const };
  await ledger.begin(key, "request", 0, undefined, supplied ? undefined : generated);
  await ledger.reserve("vm", 3, 0, 0, `slot-${n}`);
  await ledger.advance(key, { phase: "creating", vmId: id, reservationId: `slot-${n}`, context: "context", createdBy: "key:owner",
    dispatch: { state: "sent", token: "send" } }, 1);
  return { id, key, generated };
};

it("reads active slots without scanning completed history, and removes settled or cancelled work", async () => {
  const storage = memoryLedgerStorage(); let historyScans = 0;
  const metered = (view: LedgerStorage): LedgerStorage => ({
    get: key => view.get(key), put: (key, value) => view.put(key, value), delete: key => view.delete(key),
    list: options => { if (options.prefix === "idem:") historyScans++; return view.list(options); },
    transaction: work => view.transaction(tx => work(metered(tx))),
  });
  const ledger = new TenantLedger(metered(storage));
  for (let n = 0; n < 128; n++) {
    const value = await retained(ledger, n);
    await ledger.advance(value.key, { phase: "done", vmId: value.id }, 2);
  }
  const first = await retained(ledger, 200), second = await retained(ledger, 201);
  historyScans = 0;
  expect((await ledger.listGenerated("tenant", undefined, 50, true)).items.map(x => x.key)).toEqual([second.generated.key, first.generated.key]);
  expect(historyScans).toBe(0);
  await ledger.cancelCreation(second.key, second.id);
  expect((await ledger.listGenerated("tenant", undefined, 50, true)).items).toHaveLength(2);
  await ledger.settleCancellation(second.key, second.id);
  await ledger.settleCreation(first.key, first.id, 3);
  expect(await ledger.listGenerated("tenant", undefined, 50, true)).toEqual({ items: [], nextCursor: null, pendingIndex: "ready" });
  expect(historyScans).toBe(0);
});

it("never publishes caller-supplied keys through a slot binding", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  await retained(ledger, 1, true);
  expect(await ledger.listGenerated("tenant", undefined, 50, true)).toEqual({ items: [], nextCursor: null, pendingIndex: "ready" });
});

it("reports unbound and malformed retained slots as incomplete without releasing them", async () => {
  for (const extra of [{}, { vmCreation: { future: true } }, { vmCreation: { key: "missing-journal", vmId: newVmId() } }]) {
    const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage);
    const held = { kind: "vm", retained: true, expiresMs: 0, ...extra };
    await storage.put("reserve:orphan", held);
    expect(await ledger.listGenerated("tenant", undefined, 50, true)).toEqual({ items: [], nextCursor: null, pendingIndex: "unavailable" });
    expect(await storage.get("reserve:orphan")).toEqual(held);
    expect(await ledger.reserve("vm", 1, 0, 90_000_000, "other")).toEqual({ ok: false });
  }
});
