import { expect, it } from "vitest";
import type { GeneratedCreation } from "../../src/domain/generated-creation.ts";
import { VmCreationKey } from "../../src/lib/ids.ts";
import { IDEMPOTENCY_TTL_MS, memoryLedgerStorage, TenantLedger } from "../../src/limits/ledger.ts";

const generated = (n: number, scope = "tenant"): GeneratedCreation => ({
  key: VmCreationKey.make(`vcr_${String(n).padStart(26, "0")}`), cursor: String(n).padStart(64, "0"),
  scope, createdBy: "key:owner", createdAt: "2026-10-18T00:00:00.000Z", displayName: null, labels: {}, operation: "create",
});
const progress = { phase: "creating" as const, vmId: "vm_00000000000000000000000001", reservationId: "slot", context: "provider", createdBy: "key:owner", dispatch: { state: "ready" as const, token: "send" } };

it("pages only indexed server handles within the requested discovery scope", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  for (let n = 1; n <= 3; n++) {
    await ledger.begin(`digest-${n}`, "request", 0, undefined, generated(n, n === 3 ? "service:other" : "tenant"));
    await ledger.reserve("vm", 20, 0, 0, "slot");
    await ledger.advance(`digest-${n}`, progress, 1);
    await ledger.advance(`digest-${n}`, { phase: "done", vmId: progress.vmId }, 2);
  }
  await ledger.begin("private-client-digest", "request", 0);
  await ledger.advance("private-client-digest", { phase: "done", vmId: progress.vmId }, 1);
  const first = await ledger.listGenerated("tenant", undefined, 1);
  expect(first.items.map((item) => item.key)).toEqual([generated(1).key]);
  expect(first.nextCursor).toBe(generated(1).cursor);
  const second = await ledger.listGenerated("tenant", first.nextCursor ?? undefined, 1);
  expect(second.items.map((item) => item.key)).toEqual([generated(2).key]);
  expect(second.nextCursor).toBeNull();
  expect((await ledger.listGenerated("service:other", undefined, 10)).items.map((item) => item.key)).toEqual([generated(3).key]);
});

it("keeps generated handles from allocating again after completion, deletion or the ordinary replay deadline", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  await ledger.begin("digest", "request", 0, undefined, generated(1));
  await ledger.reserve("vm", 1, 0, 0, "slot");
  await ledger.advance("digest", progress, 1);
  await ledger.advance("digest", { phase: "done", vmId: progress.vmId }, 2);
  const later = IDEMPOTENCY_TTL_MS * 3;
  expect(await ledger.begin("digest", "request", later)).toMatchObject({ state: "resume", progress: { phase: "done" } });
  expect(await ledger.begin("digest", "changed", later)).toEqual({ state: "mismatch" });
  expect((await ledger.listGenerated("tenant", undefined, 10)).items).toHaveLength(1);
});

it("rolls back intent, reservation promotion and discovery together if indexing fails", async () => {
  const storage = memoryLedgerStorage();
  const ledger = new TenantLedger({ ...storage, transaction: (run) => storage.transaction((tx) => run({ ...tx, put: async (key, value) => {
    if (key.startsWith("generated:")) throw Error("index unavailable");
    await tx.put(key, value);
  } })) });
  await ledger.begin("digest", "request", 0, undefined, generated(1));
  await ledger.reserve("vm", 1, 0, 0, "slot");
  await expect(ledger.advance("digest", progress, 1)).rejects.toThrow("index unavailable");
  expect((await ledger.inspect("digest"))?.progress).toEqual({ phase: "claimed" });
  expect((await ledger.listGenerated("tenant", undefined, 10)).items).toHaveLength(0);
  await ledger.release("slot");
  expect(await ledger.reserve("vm", 1, 0, 2, "replacement")).toMatchObject({ ok: true });
});

it("rotates bounded expiry work past permanent generated history", async () => {
  const ledger = new TenantLedger(memoryLedgerStorage());
  await ledger.begin("z-expired", "old", 0);
  await ledger.advance("z-expired", { phase: "done", vmId: progress.vmId }, 1);
  for (let n = 1; n <= 70; n++) {
    const key = `a-${String(n).padStart(3, "0")}`;
    await ledger.begin(key, "request", 0, undefined, generated(n));
    await ledger.advance(key, { phase: "done", vmId: progress.vmId }, 1);
  }
  for (let n = 0; n < 4; n++) await ledger.begin(`trigger-${n}`, "request", IDEMPOTENCY_TTL_MS * 3);
  expect(await ledger.inspect("z-expired")).toBeNull();
  expect((await ledger.inspect("a-050"))?.progress).toMatchObject({ phase: "done" });
});
