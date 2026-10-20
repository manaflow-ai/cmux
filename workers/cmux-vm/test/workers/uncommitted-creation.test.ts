/**
 * A create whose VM was allocated but could not be grown keeps the VM as an uncommitted
 * creation: listed and deletable by its owner, its quota slot held, never treated as finished.
 */
import { Effect, Layer } from "effect";
import { afterEach, expect, it, vi } from "vitest";
import { CREATE_SEND_GRACE_MS } from "../../src/limits/ledger.ts";
import { LimitsUnavailable, memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
afterEach(async () => { await current?.dispose(); current = undefined; });
const SIZE = { vcpus: 12 };

const setup = async (options: HarnessOptions = {}) => {
  const t = await makeHarness({ maxVms: 1, ...options }); current = t;
  const token = await t.addKey("team_alpha", ["vm:read", "vm:write"]);
  const headers = (key?: string) => ({ ...bearer(token), ...(key === undefined ? {} : { "idempotency-key": key }) });
  const create = (key?: string, resources: object | undefined = SIZE) => t.request("/v1/vms", headers(key), { method: "POST", body: { displayName: "grown agent", ...(resources === undefined ? {} : { resources }) } });
  const list = async () => (await (await t.request("/v1/vms", headers())).json<{ items: Array<{ id: string; creation?: string; resources: { vcpus: number } }> }>()).items;
  const status = (key: string) => t.request("/v1/vm-creations/by-key", headers(key));
  const reconcile = (key: string) => t.request("/v1/vm-creations/by-key/reconcile", headers(key), { method: "POST" });
  const remove = (id: string) => t.request(`/v1/vms/${id}`, headers(), { method: "DELETE" });
  const failGrow = async (key?: string) => {
    t.upstream.fail("resize", 409);
    const response = await create(key);
    expect(response.status).toBe(503);
    const { creationKey } = await response.json<{ creationKey?: string }>();
    return creationKey ?? key ?? "";
  };
  return { ...t, create, list, status, reconcile, remove, failGrow, headers };
};

/** A ledger whose abandon RPC is lost, so the failed request's claim stays held. */
const lostAbandon = async () => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  return Layer.succeed(TenantLimits, { ...base, abandon: () => Effect.void });
};

it.each([["unkeyed", undefined], ["keyed", "grow-intent"]] as const)("%s create: keeps the VM whose growth failed listed, counted and deletable", async (_kind, key) => {
  const t = await setup();
  await t.failGrow(key);
  expect(t.upstream.vms.size).toBe(1);
  expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\//)).toHaveLength(0);
  const [listed] = await t.list();
  expect(listed).toMatchObject({ creation: "pending" });
  const id = listed!.id;
  expect(await (await t.request(`/v1/vms/${id}`, t.headers())).json()).toMatchObject({ id, creation: "pending" });
  expect((await t.create(undefined, undefined)).status).toBe(429);
  expect((await t.remove(id)).status).toBe(204);
  expect(t.upstream.vms.size).toBe(0);
  expect(await t.list()).toEqual([]);
  expect((await t.create(undefined, undefined)).status).toBe(201);
});

it("resumes the grow on a same-key retry instead of replaying the uncommitted VM", async () => {
  const t = await setup();
  const key = await t.failGrow();
  const retry = await t.create(key);
  expect(retry.status).toBe(201);
  expect(await retry.json()).toMatchObject({ resources: { vcpus: 12 }, creationKey: key });
  expect((await t.list())[0]?.creation).toBeUndefined();
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(2);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  expect((await t.create(undefined, undefined)).status).toBe(429);
});

it("does not settle an uncommitted VM as finished while its failed request still holds the key", async () => {
  const t = await setup({ limits: await lostAbandon() });
  await t.failGrow("held-intent");
  expect((await t.create("held-intent")).status).toBe(409);
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
  expect((await t.create(undefined, undefined)).status).toBe(429);
  expect((await t.list())[0]).toMatchObject({ creation: "pending" });
});

it("reports and reconciles an uncommitted VM as pending without freeing its slot, then commits it once grown", async () => {
  const t = await setup();
  const key = await t.failGrow();
  expect(await (await t.status(key)).json()).toMatchObject({ state: "pending" });
  expect(await (await t.reconcile(key)).json()).toMatchObject({ state: "pending" });
  expect((await t.create(undefined, undefined)).status).toBe(429);
  [...t.upstream.vms.values()][0]!.resources.cpu = 12;
  expect(await (await t.reconcile(key)).json()).toMatchObject({ state: "committed" });
  expect((await t.list())[0]?.creation).toBeUndefined();
  expect((await t.create(undefined, undefined)).status).toBe(429);
  expect(t.upstream.callsTo("POST", /\/resize$/)).toHaveLength(1);
});

/** A ledger whose next `settleCancellation` RPC fails, as if the Durable Object were briefly unreachable. */
const failingSettle = async () => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer())); let fail = true;
  return Layer.succeed(TenantLimits, { ...base, settleCancellation: (tenant, key, vmId) => {
    if (fail) { fail = false; return Effect.fail(new LimitsUnavailable({ cause: "settle lost" })); }
    return base.settleCancellation(tenant, key, vmId);
  } });
};

it("frees the slot on a delete retry when the first delete failed after its tombstone", async () => {
  const t = await setup({ limits: await failingSettle() });
  await t.failGrow("settle-lost");
  const id = (await t.list())[0]!.id;
  expect((await t.remove(id)).status).toBe(503);
  expect(t.isDeleted(id)).toBe(true);
  expect((await t.create(undefined, undefined)).status).toBe(429);
  expect((await t.remove(id)).status).toBe(204);
  expect((await t.create(undefined, undefined)).status).toBe(201);
  expect((await t.create(undefined, undefined)).status).toBe(429);
});

it("frees the slot when a same-key retry commits the VM while its delete is failing upstream", async () => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  let race: (() => Promise<void>) | undefined;
  const t: Awaited<ReturnType<typeof setup>> = await setup({ limits: Layer.succeed(TenantLimits, { ...base, creationActive: (tenant, key, vmId) => base.creationActive(tenant, key, vmId).pipe(
    // After its grow, the retry reads its intent as active; the delete fences it before the retry records the commit.
    Effect.tap(() => {
      const run = race;
      if (run === undefined || t.upstream.callsTo("POST", /\/resize$/).length < 2) return Effect.void;
      race = undefined;
      return Effect.promise(run);
    }),
  ) }) });
  const key = await t.failGrow("commit-race");
  const id = (await t.list())[0]!.id;
  race = async () => { t.upstream.fail("delete", 503); expect((await t.remove(id)).status).toBe(503); };
  expect((await t.create(key)).status).toBe(503);
  expect((await t.list())[0]).toMatchObject({ id });
  expect((await t.list())[0]?.creation).toBeUndefined();
  expect((await t.remove(id)).status).toBe(204);
  expect(t.upstream.vms.size).toBe(0);
  expect((await t.create(undefined, undefined)).status).toBe(201);
  expect((await t.create(undefined, undefined)).status).toBe(429);
});

it("settles a pending VM the provider deleted instead of creating another on a late same-key retry", async () => {
  const t = await setup();
  const key = await t.failGrow("auto-deleted");
  const id = (await t.list())[0]!.id;
  t.upstream.vms.clear();
  vi.spyOn(Date, "now").mockReturnValue(Date.now() + CREATE_SEND_GRACE_MS + 1000);
  try {
    expect((await t.create(key)).status).toBe(404);
    expect((await t.create(key)).status).toBe(404);
  } finally { vi.restoreAllMocks(); }
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  expect(t.isDeleted(id)).toBe(true);
  expect(await (await t.status(key)).json()).toMatchObject({ state: "deleted" });
  expect((await t.create(undefined, undefined)).status).toBe(201);
  expect((await t.create(undefined, undefined)).status).toBe(429);
});

it("cleans up a pending fork's intermediate snapshot when its VM is deleted", async () => {
  const t = await setup({ maxVms: 2 });
  const source = t.addVm("team_alpha");
  t.recordFault.before = 1;
  const forked = await t.request(`/v1/vms/${source.vmId}/fork`, t.headers("pending-fork"), { method: "POST", body: {} });
  expect(forked.status).toBe(503);
  // The cancellation records the VM uncommitted, then its provider delete fails.
  t.upstream.fail("delete", 503);
  expect((await t.request("/v1/vm-creations/by-key/cancel", t.headers("pending-fork"), { method: "POST" })).status).toBe(503);
  const pending = (await t.list()).find((vm) => vm.creation === "pending");
  expect(t.upstream.snapshots.size).toBe(1);
  expect((await t.remove(pending!.id)).status).toBe(204);
  expect(t.upstream.snapshots.size).toBe(0);
});

it("frees a legacy intent's slot when its pending VM is deleted", async () => {
  const base = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  // A legacy intent has no send receipt, so the ledger refuses to fence it.
  const t = await setup({ limits: Layer.succeed(TenantLimits, { ...base, cancelCreation: () => Effect.succeed("legacy" as const) }) });
  await t.failGrow("legacy-intent");
  const id = (await t.list())[0]!.id;
  expect((await t.remove(id)).status).toBe(204);
  expect((await t.create(undefined, undefined)).status).toBe(201);
  expect((await t.create(undefined, undefined)).status).toBe(429);
});
