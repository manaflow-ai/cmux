import { env } from "cloudflare:workers";
import { Effect } from "effect";
import { expect, it } from "vitest";
import { durableObjectLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { TenantId, VmId } from "../../src/lib/ids.ts";

// Staging vm_513f095020f3de5b7672 (run 45904512885): a create whose provider send timed out was retried with the same key,
// and every retry failed in ~2 s as "persistCreateIntent (no response)" 503 until create_overdue at 300 s. The handler
// journals its intent as { receipt, probe, floors, createdAt }; a resume reads it back through the Durable Object RPC,
// decoded in the schema's field order ({ receipt, probe, createdAt, floors }), and the ledger compared the two by
// JSON.stringify, so the same intent read as "allocation intent changed". The in-memory ledger never decodes, which is
// why the handler tests resumed fine.
it("a resumed create journals the same intent it read back through native RPC", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), now = Date.now(), vmId = "vm_00000000000000000000000001";
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  await stub.begin("cloud-create:x", "request", now);
  await stub.reserve("vm", 5, 0, now, "held");
  // The order createRecordedTimed builds it in.
  const intent = {
    receipt: { id: VmId.make(vmId), displayName: "team", labels: { role: "team-vm" }, idleTimeoutSeconds: 300 },
    probe: { provider: "provider-digest", environment: "staging", request: "request-digest" },
    floors: { vcpus: 4 }, createdAt: new Date(now).toISOString(),
  };
  const first = { phase: "creating" as const, vmId, reservationId: "held", context: "ctx", createdBy: "key:owner", intent, dispatch: { state: "ready" as const, token: "t0" } };
  expect(await stub.advance("cloud-create:x", first, now + 1)).toBe(true);
  expect(await stub.beginCreateSend("cloud-create:x", vmId, "t1", now + 2)).toBe(true);
  await stub.abandon("cloud-create:x", now + 3);
  const claim = await Effect.runPromise(limits.begin(tenant, "cloud-create:x", "request"));
  expect(claim.state).toBe("resume");
  if (claim.state !== "resume" || claim.progress.phase !== "creating") throw new Error("not resumed");
  const prior = claim.progress;
  // What the retry's beforeSend journals: the prior's own fields, unchanged.
  const resumed = await Effect.runPromise(Effect.either(limits.advance(tenant, "cloud-create:x", { phase: "creating", vmId: prior.vmId, reservationId: prior.reservationId, context: prior.context, createdBy: prior.createdBy, ...(prior.intent === undefined ? {} : { intent: prior.intent }), ...(prior.dispatch === undefined ? {} : { dispatch: prior.dispatch }) })));
  expect(resumed._tag === "Left" ? resumed.left : "ok").toBe("ok");
  // A real change is still refused.
  const changed = await Effect.runPromise(Effect.either(limits.advance(tenant, "cloud-create:x", { ...prior, intent: { ...intent, floors: { vcpus: 8 } } })));
  expect(changed._tag).toBe("Left");
});
