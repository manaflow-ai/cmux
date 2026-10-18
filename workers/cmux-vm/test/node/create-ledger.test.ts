import { expect, it } from "vitest";
import { IDEMPOTENCY_TTL_MS, memoryLedgerStorage, TenantLedger, type IdempotencyProgress } from "../../src/limits/ledger.ts";

const intent: IdempotencyProgress = { phase: "creating", vmId: "vm_00000000000000000000000001", reservationId: "reserved", context: "opaque-context", createdBy: "service:team-vm" };
const held = async () => {
  const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage);
  expect(await ledger.begin("key", "request", 0)).toEqual({ state: "new" });
  expect(await ledger.reserve("vm", 1, 0, 0, "reserved")).toMatchObject({ ok: true });
  await ledger.advance("key", intent, 1);
  return { storage, ledger };
};

it("keeps an uncertain allocation and its quota reservation beyond both retention and reservation deadlines", async () => {
  const { ledger } = await held(), later = IDEMPOTENCY_TTL_MS + 1;
  await ledger.abandon("key", 2);
  await ledger.release("reserved");
  expect(await ledger.reserve("vm", 1, 0, later, "other")).toEqual({ ok: false });
  expect(await ledger.begin("key", "changed request", later)).toEqual({ state: "mismatch" });
  expect(await ledger.begin("key", "request", later)).toEqual({ state: "resume", progress: intent });
  expect(await ledger.creationReservation("key", "another-vm")).toBeNull();
  expect(await ledger.creationReservation("key", "vm_00000000000000000000000001")).toBe("reserved");
  await ledger.advance("key", { phase: "done", vmId: "vm_00000000000000000000000001" }, later + 1);
  expect(await ledger.reserve("vm", 1, 0, later + 2, "freed")).toMatchObject({ ok: true });
  expect(await ledger.begin("key", "request", later + 2)).toEqual({ state: "resume", progress: { phase: "done", vmId: "vm_00000000000000000000000001" } });
});

it("serializes simultaneous claims and refuses a changed allocation or completed journal", async () => {
  const { ledger } = await held();
  await ledger.abandon("key", 2);
  const claims = await Promise.all([ledger.begin("key", "request", 3), ledger.begin("key", "request", 3)]);
  expect(claims.map((r) => r.state)).toEqual(["resume", "in_progress"]);
  if (intent.phase !== "creating") throw Error("not a create intent");
  await expect(ledger.advance("key", { ...intent, vmId: "another-vm" }, 4)).rejects.toThrow("allocation intent changed");
  await ledger.advance("key", { phase: "done", vmId: intent.vmId }, 5);
  await expect(ledger.advance("key", intent, 6)).rejects.toThrow("completed idempotency record");
});

it("rolls quota promotion back when the allocation journal transaction fails", async () => {
  const storage = memoryLedgerStorage();
  let fail = false;
  const ledger = new TenantLedger({ ...storage, transaction: (run) => storage.transaction((tx) => run({ ...tx, put: async (key, value) => {
    if (fail && key.startsWith("idem:")) throw Error("lost write");
    await tx.put(key, value);
  } })) });
  await ledger.begin("key", "request", 0);
  await ledger.reserve("vm", 1, 0, 0, "reserved");
  fail = true;
  await expect(ledger.advance("key", intent, 1)).rejects.toThrow("lost write");
  expect(await ledger.creationReservation("key", "vm_00000000000000000000000001")).toBeNull();
  await ledger.release("reserved");
  expect(await ledger.reserve("vm", 1, 0, 2, "another")).toMatchObject({ ok: true });
});

it("does not reinterpret an expired legacy pending record as permission for a new allocation", async () => {
  const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage);
  await storage.put("idem:legacy", { fingerprint: "original", progress: { phase: "pending" }, leaseUntilMs: 0, expiresMs: 0 });
  await ledger.abandon("legacy", 1);
  await ledger.begin("unrelated", "new", IDEMPOTENCY_TTL_MS + 1);
  expect(await ledger.begin("legacy", "original", IDEMPOTENCY_TTL_MS + 2)).toEqual({ state: "in_progress" });
  expect(await ledger.begin("legacy", "changed", IDEMPOTENCY_TTL_MS + 2)).toEqual({ state: "mismatch" });
});
