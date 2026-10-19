import { expect, it } from "vitest";
import { newMeshId } from "../../src/lib/ids.ts";
import { IDEMPOTENCY_TTL_MS, memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";

const key = "1".repeat(64), fingerprint = "2".repeat(64), context = "3".repeat(64);
const prepared = async () => {
  const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage), meshId = newMeshId();
  const intent = { key, fingerprint, meshId, holder: "original", createdBy: "key:creator", displayName: "Team mesh" };
  expect(await ledger.meshCreation({ op: "begin", ...intent }, 0)).toMatchObject({ state: "record", acquired: true, record: { phase: "prepared" } });
  const lease = { key, meshId, holder: "original" };
  return { storage, ledger, intent, lease };
};
const retained = async () => {
  const h = await prepared();
  await h.ledger.reserve("mesh", 1, 0, 0, "quota");
  expect(await h.ledger.meshCreation({ op: "retain", ...h.lease, reservationId: "quota" }, 1)).toMatchObject({ state: "record", record: { phase: "creating" } });
  await h.ledger.meshCreation({ op: "context", ...h.lease, context }, 2);
  return h;
};

it("retains labelled intent through lease owners and refuses changing it through the legacy command", async () => {
  const storage = memoryLedgerStorage(), ledger = new TenantLedger(storage), meshId = newMeshId();
  const intent = { key, fingerprint, meshId, holder: "first", createdBy: "service:cloud", displayName: null };
  expect(await ledger.meshCreation({ op: "begin-labelled", ...intent, labels: { role: "cloud", cmux_mesh_creation: key } }, 0)).toMatchObject({ state: "record", record: { labels: { role: "cloud" } } });
  await ledger.meshCreation({ op: "abandon", key, meshId, holder: "first" }, 1);
  const restarted = new TenantLedger(storage);
  expect(await restarted.meshCreation({ op: "begin-labelled", ...intent, holder: "second", labels: { cmux_mesh_creation: key, role: "cloud" } }, 2)).toMatchObject({ state: "record", acquired: true, record: { labels: { role: "cloud" } } });
  expect(await restarted.meshCreation({ op: "begin-labelled", ...intent, labels: { role: "other", cmux_mesh_creation: key } }, 3)).toEqual({ state: "conflict" });
  expect(await restarted.meshCreation({ op: "begin", ...intent }, 3)).toEqual({ state: "conflict" });
});

it("retains the original identity, creator and request binding across lease owners", async () => {
  const { ledger, intent, lease } = await prepared();
  expect(await ledger.meshCreation({ op: "begin", ...intent, fingerprint: "4".repeat(64) }, 1)).toEqual({ state: "conflict" });
  expect(await ledger.meshCreation({ op: "begin", ...intent, holder: "next" }, 1)).toMatchObject({ state: "record", acquired: false });
  await ledger.meshCreation({ op: "abandon", ...lease }, 2);
  expect(await ledger.meshCreation({ op: "begin", ...intent, meshId: newMeshId(), createdBy: "key:rotated", holder: "next" }, 3)).toMatchObject({ state: "record", acquired: true,
    record: { meshId: intent.meshId, createdBy: intent.createdBy, createdAt: new Date(0).toISOString(), holder: "next" } });
  await ledger.meshCreation({ op: "abandon", ...lease }, 4);
  expect(await ledger.meshCreation({ op: "active", ...lease, holder: "next" }, 5)).toEqual({ state: "ok" });
  expect(await ledger.meshCreation({ op: "active", ...lease }, 5)).toEqual({ state: "denied" });
});

it("persists uncertain sends and quota beyond ordinary sweeping and restarts", async () => {
  const { ledger, storage, lease, intent } = await retained();
  expect(await ledger.meshCreation({ op: "send", ...lease, token: "once" }, 3)).toMatchObject({ state: "record" });
  await ledger.release("quota");
  const later = IDEMPOTENCY_TTL_MS * 3, restarted = new TenantLedger(storage);
  await restarted.begin("unrelated", "fingerprint", later);
  expect(await restarted.reserve("mesh", 1, 0, later, "extra")).toEqual({ ok: false });
  expect(await restarted.meshCreation({ op: "begin", ...intent, holder: "next" }, later)).toMatchObject({ state: "record", acquired: true, record: { dispatch: { state: "sent", token: "once" } } });
  expect(await restarted.meshCreation({ op: "send", ...lease, holder: "next", token: "twice" }, later + 1)).toEqual({ state: "denied" });
  expect(await restarted.meshCreation({ op: "reservation", key, meshId: lease.meshId }, later + 1)).toEqual({ state: "reservation", reservationId: "quota" });
});

it("reopens only a definitively rejected dispatch and fences stale rejection tokens", async () => {
  const { ledger, lease } = await retained();
  await ledger.meshCreation({ op: "send", ...lease, token: "first" }, 3);
  expect(await ledger.meshCreation({ op: "context", ...lease, context: "4".repeat(64) }, 4)).toEqual({ state: "denied" });
  expect(await ledger.meshCreation({ op: "reject", ...lease, token: "wrong" }, 4)).toEqual({ state: "denied" });
  expect(await ledger.meshCreation({ op: "reject", ...lease, token: "first" }, 4)).toMatchObject({ state: "record" });
  expect(await ledger.meshCreation({ op: "context", ...lease, context: "4".repeat(64) }, 5)).toMatchObject({ state: "record" });
  expect(await ledger.meshCreation({ op: "send", ...lease, token: "second" }, 6)).toMatchObject({ state: "record" });
  expect(await ledger.meshCreation({ op: "reject", ...lease, token: "first" }, 7)).toEqual({ state: "denied" });
  expect(await ledger.meshCreation({ op: "send", ...lease, token: "third" }, 8)).toEqual({ state: "denied" });
});

it("fences cancellation before late sends or completion and retains quota until deletion", async () => {
  const { ledger, lease, intent } = await retained();
  await ledger.meshCreation({ op: "send", ...lease, token: "first" }, 3);
  expect(await ledger.meshCreation({ op: "cancel", ...lease }, 4)).toMatchObject({ state: "record", record: { phase: "cancelling" } });
  for (const op of ["active", "send", "complete", "reject"] as const) {
    expect(await ledger.meshCreation({ op, ...lease, token: "first" }, 5)).toEqual({ state: "denied" });
  }
  expect(await ledger.reserve("mesh", 1, 0, IDEMPOTENCY_TTL_MS * 3, "extra")).toEqual({ ok: false });
  expect(await ledger.meshCreation({ op: "cancelled", ...lease }, 6)).toMatchObject({ state: "record", record: { phase: "deleted" } });
  expect(await ledger.reserve("mesh", 1, 0, 7, "extra")).toMatchObject({ ok: true });
  expect(await ledger.meshCreation({ op: "begin", ...intent }, IDEMPOTENCY_TTL_MS * 4)).toMatchObject({ state: "record", acquired: false, record: { phase: "deleted" } });
  expect(await ledger.meshCreation({ op: "complete", ...lease }, 8)).toEqual({ state: "denied" });
});

it("settles quota after ownership and never expires a completed request binding", async () => {
  const { ledger, lease, intent } = await retained();
  expect(await ledger.meshCreation({ op: "complete", ...lease, meshId: newMeshId() }, 3)).toEqual({ state: "denied" });
  expect(await ledger.meshCreation({ op: "complete", ...lease }, 4)).toMatchObject({ state: "record", record: { phase: "done" } });
  expect(await ledger.reserve("mesh", 1, 0, 5, "extra")).toMatchObject({ ok: true });
  expect(await ledger.meshCreation({ op: "begin", ...intent }, IDEMPOTENCY_TTL_MS * 4)).toMatchObject({ state: "record", acquired: false, record: { phase: "done" } });
  expect(await ledger.meshCreation({ op: "begin", ...intent, fingerprint: "4".repeat(64) }, IDEMPOTENCY_TTL_MS * 4)).toEqual({ state: "conflict" });
});

it("does not reinterpret corrupt or future durable records as a fresh intent", async () => {
  const { ledger, storage, intent } = await prepared();
  const original = await storage.get(`mesh-create-v1:${key}`);
  if (typeof original !== "object" || original === null) throw Error("missing journal");
  for (const patch of [{ version: 2 }, { phase: "future" }, { meshId: "invalid" }]) {
    await storage.put(`mesh-create-v1:${key}`, { ...original, ...patch });
    await expect(ledger.meshCreation({ op: "begin", ...intent }, IDEMPOTENCY_TTL_MS * 4)).rejects.toThrow("unrecognized mesh creation record");
    expect(await storage.get(`mesh-create-v1:${key}`)).toEqual({ ...original, ...patch });
  }
});

it("rolls back quota promotion if the durable intent write fails", async () => {
  const { storage, lease } = await prepared();
  const ledger = new TenantLedger({ ...storage, transaction: (run) => storage.transaction((tx) => run({ ...tx, put: async (k, value) => {
    if (k.startsWith("mesh-create-v1:")) throw Error("intent write lost");
    await tx.put(k, value);
  } })) });
  await ledger.reserve("mesh", 1, 0, 0, "quota");
  await expect(ledger.meshCreation({ op: "retain", ...lease, reservationId: "quota" }, 1)).rejects.toThrow("intent write lost");
  await ledger.release("quota");
  expect(await ledger.reserve("mesh", 1, 0, 2, "replacement")).toMatchObject({ ok: true });
});
