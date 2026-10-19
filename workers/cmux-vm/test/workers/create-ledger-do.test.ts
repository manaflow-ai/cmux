import { env } from "cloudflare:workers";
import { Effect, Exit } from "effect";
import { expect, it } from "vitest";
import { IDEMPOTENCY_TTL_MS } from "../../src/limits/ledger.ts";
import { durableObjectLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { newSnapshotId, newVmId, TenantId, VmId, VmCreationKey } from "../../src/lib/ids.ts";

it("retains fork capture identity, quota and cancellation through native RPC", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), vmId = newVmId(), now = Date.now();
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  await stub.begin("fork", "request", now);
  await stub.reserve("vm", 1, 0, now, "fork-slot");
  const progress = { phase: "capturing" as const, vmId, sourceVmId: newVmId(), snapshotId: newSnapshotId(), captureKey: "child",
    reservationId: "fork-slot", createdBy: "key:owner", createdAt: new Date(now).toISOString(),
    receipt: { id: vmId, displayName: null, labels: {}, idleTimeoutSeconds: 300 } };
  expect(await stub.advance("fork", progress, now + 1)).toBe(true);
  const reloaded = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  expect((await Effect.runPromise(limits.inspect(tenant, "fork")))?.progress).toEqual(progress);
  expect(await reloaded.reserve("vm", 1, 0, now + IDEMPOTENCY_TTL_MS * 3, "other")).toEqual({ ok: false });
  expect(await reloaded.cancelCreation("fork", vmId)).toBe("accepted");
  expect(await reloaded.settleCancellation("fork", vmId)).toBe(false);
  await reloaded.snapshotCapture({ op: "fence", key: "child", expectedId: null, createdBy: "key:owner", labels: {} }, now + 2);
  expect(await reloaded.settleCancellation("fork", vmId)).toBe(true);
  expect((await Effect.runPromise(limits.inspect(tenant, "fork")))?.progress).toMatchObject({ phase: "capturing", cancelled: true });
  expect(await reloaded.advance("fork", { phase: "done", vmId }, now + 3)).toBe(false);
  await reloaded.begin("legacy", "old", 0);
  expect(await Effect.runPromise(limits.quarantineForkClaim(tenant, "legacy"))).toBe(true);
  await reloaded.begin("sweep", "unrelated", now + IDEMPOTENCY_TTL_MS * 3);
  expect(await reloaded.begin("legacy", "old", now + IDEMPOTENCY_TTL_MS * 3)).toEqual({ state: "in_progress" });
  await reloaded.begin("live-claim", "busy", now);
  expect(await Effect.runPromise(limits.quarantineForkClaim(tenant, "live-claim"))).toBe(false);
  expect((await Effect.runPromise(limits.inspect(tenant, "live-claim")))?.progress.phase).toBe("claimed");
});

it("persists generated history and permanent replay through native RPC serialization", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), now = Date.now();
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  const generated = { key: VmCreationKey.make("vcr_00000000000000000000000001"), cursor: "a".repeat(64), scope: "tenant",
    createdBy: "key:owner", createdAt: "2026-10-18T00:00:00Z", displayName: null, labels: {}, operation: "create" as const };
  expect(await Effect.runPromise(limits.begin(tenant, "native-generated", "request", undefined, generated))).toEqual({ state: "new" });
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  const id = "vm_00000000000000000000000001";
  await stub.reserve("vm", 1, 0, now, "held-generated");
  expect(await stub.advance("native-generated", { phase: "creating", vmId: id, reservationId: "held-generated", context: "provider", createdBy: "key:owner" }, now + 1)).toBe(true);
  expect(await Effect.runPromise(limits.listGenerated(tenant, "tenant", undefined, 1))).toEqual({ items: [generated], nextCursor: null });
  expect(await Effect.runPromise(limits.listGenerated(tenant, "service:other", undefined, 1))).toEqual({ items: [], nextCursor: null });
  expect(await stub.advance("native-generated", { phase: "done", vmId: id }, now + 2)).toBe(true);
  expect(await stub.begin("native-generated", "request", now + IDEMPOTENCY_TTL_MS * 3)).toMatchObject({ state: "resume", progress: { phase: "done", vmId: id } });
  expect((await Effect.runPromise(limits.inspect(tenant, "native-generated")))?.generated).toEqual(generated);
});

it("keeps the admitted client request binding through native RPC, completion and later retries", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), now = Date.now();
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  expect(await Effect.runPromise(limits.begin(tenant, "image", "resolved-image", "client-request"))).toEqual({ state: "new" });
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  expect(await stub.advance("image", { phase: "done", vmId: "vm_00000000000000000000000001" }, now + 1)).toBe(true);
  expect(await Effect.runPromise(limits.begin(tenant, "image", "resolved-image", "different-client-request"))).toEqual({ state: "mismatch" });
  expect((await Effect.runPromise(limits.inspect(tenant, "image")))?.clientFingerprint).toBe("client-request");
  expect(await Effect.runPromise(limits.begin(tenant, "image", "resolved-image", "client-request"))).toMatchObject({ state: "resume", progress: { phase: "done" } });
  // An older Worker can still replay using its original resolved fingerprint.
  expect(await stub.begin("image", "resolved-image", now + 2)).toMatchObject({ state: "resume", progress: { phase: "done" } });
  await stub.begin("legacy-image", "legacy-resolved", now);
  expect(await stub.advance("legacy-image", { phase: "done", vmId: "vm_00000000000000000000000002" }, now + 1)).toBe(true);
  expect(await Effect.runPromise(limits.begin(tenant, "legacy-image", "legacy-resolved", "unproven-client"))).toMatchObject({ state: "resume" });
  expect((await Effect.runPromise(limits.inspect(tenant, "legacy-image")))?.clientFingerprint).toBeUndefined();
});

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


it("decodes retained creation evidence and settles it after lease expiry across native RPC", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  const now = Date.now(), vmId = "vm_00000000000000000000000001";
  await stub.begin("creation", "request", now);
  await stub.reserve("vm", 1, 0, now, "held");
  expect(await stub.advance("creation", { phase: "creating", vmId, reservationId: "held", context: "opaque", createdBy: "service:team-vm", intent: {
    receipt: { id: VmId.make(vmId), displayName: "team", labels: { role: "team-vm" }, idleTimeoutSeconds: 300 },
    createdAt: new Date(now).toISOString(), floors: { vcpus: 4 }, probe: { provider: "provider-digest", environment: "test", request: "request-digest" },
  } }, now + 1)).toBe(true);
  expect(await stub.settleCreation("creation", "wrong", now + IDEMPOTENCY_TTL_MS)).toBe(false);
  const layer = durableObjectLimitsLayer(env.TENANT_LIMITS);
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, layer));
  expect((await Effect.runPromise(limits.inspect(tenant, "creation")))?.progress).toMatchObject({ phase: "creating", vmId, intent: { receipt: { id: vmId }, floors: { vcpus: 4 } } });
  expect(await stub.settleCreation("creation", vmId, now + IDEMPOTENCY_TTL_MS)).toBe(true);
  expect((await Effect.runPromise(limits.inspect(tenant, "creation")))?.progress).toEqual({ phase: "done", vmId });
  expect(await stub.reserve("vm", 1, 0, now + IDEMPOTENCY_TTL_MS + 1, "free")).toMatchObject({ ok: true });
});

it("serializes dispatch and cancellation through the native RPC and retains the tombstone", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  const id = "vm_00000000000000000000000001", now = Date.now();
  await stub.begin("cancel", "request", now);
  await stub.reserve("vm", 1, 0, now, "held");
  expect(await stub.advance("cancel", { phase: "creating", vmId: id, reservationId: "held", context: "digest", createdBy: "key:owner", dispatch: { state: "ready", token: "ready" } }, now + 1)).toBe(true);
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  expect(await Effect.runPromise(limits.beginCreateSend(tenant, "cancel", id, "original"))).toBe(true);
  expect(await Effect.runPromise(limits.cancelCreation(tenant, "cancel", id))).toBe("accepted");
  expect(await Effect.runPromise(limits.beginCreateSend(tenant, "cancel", id, "late"))).toBe(false);
  await Effect.runPromise(limits.rejectCreateSend(tenant, "cancel", id, "original"));
  expect((await Effect.runPromise(limits.inspect(tenant, "cancel")))?.progress).toMatchObject({ phase: "cancelled" });
  expect(await stub.begin("cancel", "request", now + IDEMPOTENCY_TTL_MS * 3)).toMatchObject({ state: "resume", progress: { phase: "cancelled" } });
});

it("persists snapshot capture fences and quota through the actual native RPC", async () => {
  const tenant = TenantId.make(crypto.randomUUID()), now = Date.now();
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  const id = newSnapshotId(), intent = { id, sourceVmId: newVmId(), displayName: null, labels: {}, createdBy: "service:cloud",
    createdAt: new Date(now).toISOString(), ttlSeconds: null, autoDeleteSeconds: null };
  await Effect.runPromise(limits.snapshotCapture(tenant, { op: "begin", key: "snapshot", fingerprint: "request", intent, nonce: "lease" }));
  const reserved = await Effect.runPromise(limits.reserve(tenant, "snapshot", 1, 0));
  if (!reserved.ok) throw new Error("reservation missing");
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "prepare", id, nonce: "lease", reservationId: reserved.reservationId,
    probe: { context: "context", source: "source", stamp: "stamp" } }))).toMatchObject({ granted: true });
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "send", id, token: "one" }))).toMatchObject({ granted: true });
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "send", id, token: "two" }))).toMatchObject({ granted: false });
  await Effect.runPromise(limits.snapshotCapture(tenant, { op: "cancel", id }));
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "commit", id }))).toMatchObject({ granted: false });
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant));
  expect(await stub.reserve("snapshot", 1, 0, now + IDEMPOTENCY_TTL_MS * 2, "held")).toEqual({ ok: false });
  await Effect.runPromise(limits.snapshotCapture(tenant, { op: "cancelled", id }));
  expect(await stub.snapshotCapture({ op: "get", id }, now + IDEMPOTENCY_TTL_MS * 2)).toMatchObject({ record: { state: "cancelled" } });
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "list", limit: 1 }))).toMatchObject({ state: "page", items: [{ intent: { id } }] });
});

it("persists an absent-key cancellation fence across native RPC calls and future claims", async () => {
  const tenant = TenantId.make(crypto.randomUUID());
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, durableObjectLimitsLayer(env.TENANT_LIMITS)));
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "fence", key: "never-admitted", expectedId: null, createdBy: "service:cloud", labels: { role: "cloud" } }))).toMatchObject({ state: "fenced", granted: true });
  const stub = env.TENANT_LIMITS.get(env.TENANT_LIMITS.idFromName(tenant)), id = newSnapshotId();
  expect(await stub.snapshotCapture({ op: "begin", key: "never-admitted", fingerprint: "late", nonce: "late", intent: { id, sourceVmId: newVmId(), displayName: null, labels: { role: "cloud" }, createdBy: "service:cloud", createdAt: new Date().toISOString(), ttlSeconds: null, autoDeleteSeconds: null } }, Date.now() + IDEMPOTENCY_TTL_MS * 3)).toMatchObject({ state: "fenced" });
  expect(await Effect.runPromise(limits.snapshotCapture(tenant, { op: "inspect", key: "never-admitted" }))).toMatchObject({ state: "fenced", fence: { createdBy: "service:cloud" } });
});
