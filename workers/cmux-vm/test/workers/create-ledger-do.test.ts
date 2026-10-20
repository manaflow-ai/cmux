import { env } from "cloudflare:workers";
import { Effect, Exit } from "effect";
import { expect, it } from "vitest";
import { IDEMPOTENCY_TTL_MS } from "../../src/limits/ledger.ts";
import { durableObjectLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { TenantId } from "../../src/lib/ids.ts";

it("persists recovery identity and retained quota through the real SQLite-backed Durable Object RPC", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), id = env.TENANT_LIMITS.idFromName(tenant), first = env.TENANT_LIMITS.get(id);
  const now = Date.now();
  expect(await first.begin("request", "fingerprint", now)).toEqual({ state: "new" });
  expect(await first.reserve("vm", 1, 0, now, "slot")).toMatchObject({ ok: true });
  const intent = { phase: "creating" as const, vmId: "vm_00000000000000000000000001", reservationId: "slot", createdBy: "service:team-vm", context: "opaque-context" };
  expect(await first.advance("request", intent, now + 1)).toBe(true);
  await first.abandon("request", now + 2);
  await first.release("slot");
  const reloaded = env.TENANT_LIMITS.get(id), later = now + IDEMPOTENCY_TTL_MS + 1;
  expect(await reloaded.reserve("vm", 1, 0, later, "extra")).toEqual({ ok: false });
  expect(await reloaded.begin("request", "fingerprint", later)).toEqual({ state: "resume", progress: intent });
  expect(await reloaded.creationReservation("request", intent.vmId)).toBe("slot");
  const failedWrite = await Effect.runPromiseExit(Effect.provide(
    Effect.flatMap(TenantLimits, (limits) => limits.advance(tenant, "request", { phase: "done", vmId: "different-allocation" })),
    durableObjectLimitsLayer(env.TENANT_LIMITS),
  ));
  expect(Exit.isFailure(failedWrite)).toBe(true);
  expect(await reloaded.reserve("vm", 1, 0, later + 2, "still-blocked")).toEqual({ ok: false });
  expect(await reloaded.advance("request", { phase: "done", vmId: intent.vmId }, later + 3)).toBe(true);
  expect(await reloaded.reserve("vm", 1, 0, later + 4, "free")).toMatchObject({ ok: true });
});

it("admits only one simultaneous claimant to the last quota slot on the real storage adapter", async () => {
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(crypto.randomUUID()));
  const results = await Promise.all([stub.reserve("vm", 1, 0, 0, "a"), stub.reserve("vm", 1, 0, 0, "b")]);
  expect(results.filter((r) => r.ok)).toHaveLength(1);
});
