import { expect, it } from "vitest";
import { IDEMPOTENCY_TTL_MS, memoryLedgerStorage, TenantLedger, type IdempotencyProgress } from "../../src/limits/ledger.ts";

it("preserves the original client digest across cancellation and starts a fresh binding only after an ordinary record expires", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  expect(await ledger.begin("cancelled-image", "resolved", 0, "original-client")).toEqual({ state: "new" });
  await ledger.reserve("vm", 1, 0, 0, "held-image");
  const id = "vm_00000000000000000000000001";
  await ledger.advance("cancelled-image", { phase: "creating", vmId: id, reservationId: "held-image", context: "provider", createdBy: "service:cloud", dispatch: { state: "ready", token: "initial" } }, 1);
  expect(await ledger.cancelCreation("cancelled-image", id)).toBe("accepted");
  expect(await ledger.begin("cancelled-image", "resolved", IDEMPOTENCY_TTL_MS * 3, "changed-client")).toEqual({ state: "mismatch" });
  expect((await ledger.inspect("cancelled-image"))?.clientFingerprint).toBe("original-client");
  expect(await ledger.begin("cancelled-image", "resolved", IDEMPOTENCY_TTL_MS * 3, "original-client")).toMatchObject({ state: "resume", progress: { phase: "cancelled" } });
  await ledger.begin("ordinary", "resolved", 0, "old-client");
  await ledger.advance("ordinary", { phase: "done", vmId: id }, 1);
  expect(await ledger.begin("ordinary", "different-image", IDEMPOTENCY_TTL_MS * 3, "new-client")).toEqual({ state: "new" });
  expect((await ledger.inspect("ordinary"))?.clientFingerprint).toBe("new-client");
});

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


it("inspects without claiming or renewing and settles committed ownership after the original lease expired", async () => {
  const { ledger } = await held();
  expect((await ledger.inspect("key"))?.leaseUntilMs).toBe(600001);
  expect(await ledger.inspect("unknown")).toBeNull();
  await expect(ledger.settleCreation("key", "different", IDEMPOTENCY_TTL_MS + 2)).rejects.toThrow("intent changed");
  expect(await ledger.reserve("vm", 1, 0, IDEMPOTENCY_TTL_MS + 2, "other")).toEqual({ ok: false });
  await ledger.settleCreation("key", "vm_00000000000000000000000001", IDEMPOTENCY_TTL_MS + 3);
  expect((await ledger.inspect("key"))?.progress).toEqual({ phase: "done", vmId: "vm_00000000000000000000000001" });
  expect(await ledger.reserve("vm", 1, 0, IDEMPOTENCY_TTL_MS + 4, "other")).toMatchObject({ ok: true });
});

const dispatchable = async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  await ledger.begin("fenced", "request", 0);
  await ledger.reserve("vm", 1, 0, 0, "slot");
  await ledger.advance("fenced", { phase: "creating", vmId: "vm_00000000000000000000000001", reservationId: "slot", createdBy: "key:owner", context: "digest", dispatch: { state: "ready", token: "initial" } }, 1);
  return ledger;
};
it("grants only one unknown provider send and fences cancellation beyond retention", async () => {
  const ledger = await dispatchable(), id = "vm_00000000000000000000000001";
  const grants = await Promise.all([ledger.beginCreateSend("fenced", id, "a"), ledger.beginCreateSend("fenced", id, "b")]);
  expect(grants.filter(Boolean)).toHaveLength(1);
  expect(await ledger.cancelCreation("fenced", id)).toBe("accepted");
  expect(await ledger.creationActive("fenced", id)).toBe(false);
  expect(await ledger.beginCreateSend("fenced", id, "late")).toBe(false);
  expect(await ledger.reserve("vm", 1, 0, IDEMPOTENCY_TTL_MS * 2, "replacement")).toEqual({ ok: false });
  await expect(ledger.settleCreation("fenced", id, IDEMPOTENCY_TTL_MS * 2)).rejects.toThrow("intent changed");
  expect(await ledger.begin("fenced", "request", IDEMPOTENCY_TTL_MS * 2)).toMatchObject({ state: "resume", progress: { phase: "creating", cancelRequested: true } });
  expect(await ledger.settleCancellation("fenced", id)).toBe(true);
  expect(await ledger.begin("fenced", "request", IDEMPOTENCY_TTL_MS * 3)).toMatchObject({ state: "resume", progress: { phase: "cancelled" } });
  expect(await ledger.reserve("vm", 1, 0, IDEMPOTENCY_TTL_MS * 3, "replacement")).toMatchObject({ ok: true });
});
it("cancels before dispatch immediately and never reopens the original key", async () => {
  const ledger = await dispatchable(), id = "vm_00000000000000000000000001";
  expect(await ledger.cancelCreation("fenced", id)).toBe("accepted");
  expect((await ledger.inspect("fenced"))?.progress).toMatchObject({ phase: "cancelled" });
  expect(await ledger.beginCreateSend("fenced", id, "late")).toBe(false);
  expect(await ledger.begin("fenced", "request", IDEMPOTENCY_TTL_MS * 5)).toMatchObject({ state: "resume", progress: { phase: "cancelled" } });
});
it("allows a verified rejection to reopen only its own send and refuses legacy cancellation", async () => {
  const ledger = await dispatchable(), id = "vm_00000000000000000000000001";
  expect(await ledger.beginCreateSend("fenced", id, "first")).toBe(true);
  expect(await ledger.rejectCreateSend("fenced", id, "not-first")).toBe(false);
  expect(await ledger.rejectCreateSend("fenced", id, "first")).toBe(true);
  expect(await ledger.beginCreateSend("fenced", id, "second")).toBe(true);
  expect(await ledger.rejectCreateSend("fenced", id, "first")).toBe(false);
  await ledger.cancelCreation("fenced", id);
  expect(await ledger.rejectCreateSend("fenced", id, "second")).toBe(true);
  expect((await ledger.inspect("fenced"))?.progress).toMatchObject({ phase: "cancelled" });
  const legacy = await held();
  expect(await legacy.ledger.cancelCreation("key", id)).toBe("legacy");
  expect(await legacy.ledger.beginCreateSend("key", id, "unsafe")).toBe(false);
});
