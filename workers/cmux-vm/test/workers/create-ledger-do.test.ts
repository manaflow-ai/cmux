import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import { IDEMPOTENCY_TTL_MS } from "../../src/limits/ledger.ts";

it("persists recovery identity and retained quota through the real SQLite-backed Durable Object RPC", async () => {
  const id = env.TENANT_LIMITS.idFromName(crypto.randomUUID()), first = env.TENANT_LIMITS.get(id);
  expect(await first.begin("request", "fingerprint", 0)).toEqual({ state: "new" });
  expect(await first.reserve("vm", 1, 0, 0, "slot")).toMatchObject({ ok: true });
  const intent = { phase: "creating" as const, vmId: "vm_00000000000000000000000001", reservationId: "slot", createdBy: "service:team-vm", context: "opaque-context" };
  await first.advance("request", intent, 1);
  await first.abandon("request", 2);
  await first.release("slot");
  const reloaded = env.TENANT_LIMITS.get(id), later = IDEMPOTENCY_TTL_MS + 1;
  expect(await reloaded.reserve("vm", 1, 0, later, "extra")).toEqual({ ok: false });
  expect(await reloaded.begin("request", "fingerprint", later)).toEqual({ state: "resume", progress: intent });
  expect(await reloaded.creationReservation("request", intent.vmId)).toBe("slot");
  await expect(reloaded.advance("request", { phase: "done", vmId: "different-allocation" }, later + 1)).rejects.toThrow("allocation intent cannot be replaced");
  expect(await reloaded.reserve("vm", 1, 0, later + 2, "still-blocked")).toEqual({ ok: false });
  await reloaded.advance("request", { phase: "done", vmId: intent.vmId }, later + 3);
  expect(await reloaded.reserve("vm", 1, 0, later + 4, "free")).toMatchObject({ ok: true });
});

it("admits only one simultaneous claimant to the last quota slot on the real storage adapter", async () => {
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(crypto.randomUUID()));
  const results = await Promise.all([stub.reserve("vm", 1, 0, 0, "a"), stub.reserve("vm", 1, 0, 0, "b")]);
  expect(results.filter((r) => r.ok)).toHaveLength(1);
});
