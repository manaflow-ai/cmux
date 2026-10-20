/**
 * A create whose VM was allocated but could not be grown keeps the VM as an uncommitted
 * creation: listed and deletable by its owner, its quota slot held, never treated as finished.
 */
import { Effect, Layer } from "effect";
import { afterEach, expect, it } from "vitest";
import { memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
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
