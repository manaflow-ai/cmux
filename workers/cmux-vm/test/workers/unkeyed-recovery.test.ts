import { afterEach, beforeEach, expect, it } from "vitest";
import { Effect, Layer } from "effect";
import { LimitsUnavailable, memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
let token: string;
beforeEach(async () => { h = await makeHarness({ maxVms: 1 }); token = await h.addKey("team_alpha", ["vm:read", "vm:write"]); });
afterEach(async () => { await h.dispose(); });
const headers = (key?: string, credential = token) => ({ ...bearer(credential), ...(key === undefined ? {} : { "idempotency-key": key }) });
const create = (key?: string, credential = token) => h.request("/v1/vms", headers(key, credential), { method: "POST", body: { displayName: "recoverable agent" } });
const history = (query = "", credential = token) => h.request(`/v1/vm-creations${query}`, headers(undefined, credential));
const allocations = () => h.upstream.callsTo("POST", /^\/v5\/vms$/);
const handle = async (response: Response) => {
  const body = await response.json<{ creationKey?: string }>();
  expect(body.creationKey).toMatch(/^vcr_[0-9a-hjkmnp-tv-z]{26}$/);
  if (body.creationKey === undefined) throw Error("no recovery handle");
  return body.creationKey;
};

it("returns a stable server-issued handle when the client omits its key", async () => {
  const first = await create(); expect(first.status).toBe(201);
  const key = await handle(first);
  const replay = await create(key); expect(replay.status).toBe(201);
  expect(await replay.json()).toMatchObject({ creationKey: key });
  const page = await history(); expect(page.status).toBe(200);
  expect(await page.json()).toMatchObject({ items: [{ creationKey: key, state: "committed", operation: "create" }], nextCursor: null });
  expect(allocations()).toHaveLength(1);
});

it("retains quota after a failed ownership write and exposes the pending allocation for reconciliation", async () => {
  h.recordFault.before = 1;
  const first = await create(); expect(first.status).toBe(503);
  expect((await create()).status).toBe(429);
  const key = await handle(first);
  const page = await history(); expect(page.status).toBe(200);
  expect(await page.json()).toMatchObject({ items: [{ creationKey: key, state: "pending" }] });
  const recovered = await h.request("/v1/vm-creations/by-key/reconcile", headers(key), { method: "POST" });
  expect(recovered.status).toBe(200);
  expect(await recovered.json()).toMatchObject({ state: "committed" });
  expect(h.resources).toHaveLength(1);
  expect(allocations()).toHaveLength(1);
});

it("discovers a lost error response, cancels the allocation and never reuses its generated handle", async () => {
  h.recordFault.before = 1;
  expect((await create()).status).toBe(503);
  const page = await history(); expect(page.status).toBe(200);
  const { items } = await page.json<{ items: Array<{ creationKey: string }> }>();
  expect(items).toHaveLength(1);
  const key = items[0]!.creationKey;
  const cancelled = await h.request("/v1/vm-creations/by-key/cancel", headers(key), { method: "POST" });
  expect(cancelled.status).toBe(200);
  expect(await cancelled.json()).toMatchObject({ state: "cancelled" });
  expect((await create(key)).status).toBe(409);
  expect(h.upstream.vms.size).toBe(0);
  expect((await create()).status).toBe(201);
  expect(allocations()).toHaveLength(2);
});

it("keeps an unknown provider send accounted and never retries it through reconciliation", async () => {
  const fetch = h.upstream.fetch; let sends = 0;
  h.upstream.fetch = async (request) => {
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms") { sends++; throw new TypeError("unknown response"); }
    return fetch(request);
  };
  const first = await create(); expect(first.status).toBe(503);
  expect((await create()).status).toBe(429);
  const key = await handle(first);
  const reconciled = await h.request("/v1/vm-creations/by-key/reconcile", headers(key), { method: "POST" });
  expect(reconciled.status).toBe(200);
  expect(await reconciled.json()).toMatchObject({ state: "pending" });
  expect(sends).toBe(1);
});

it("never publishes client-supplied keys through responses, history or cursors", async () => {
  const response = await create("private-client-key-never-publish"); expect(response.status).toBe(201);
  expect(await response.json()).not.toHaveProperty("creationKey");
  const page = await history(); expect(page.status).toBe(200);
  expect(await page.json()).toEqual({ items: [], nextCursor: null });
});

it("requires read scope and an unrestricted credential for history, with tenant isolation", async () => {
  expect((await create()).status).toBe(201);
  const write = await h.addKey("team_alpha", ["vm:write"]);
  expect((await history("", write)).status).toBe(403);
  const limited = await h.addKey("team_alpha", ["vm:read"], { allowlist: [] });
  expect((await history("", limited)).status).toBe(403);
  const other = await h.addKey("team_bravo", ["vm:read"]);
  const page = await history("", other); expect(page.status).toBe(200);
  expect(await page.json()).toEqual({ items: [], nextCursor: null });
});

it("pages stable public handles without exposing private keys or using provider I/O", async () => {
  const expected: string[] = [];
  for (let n = 0; n < 3; n++) {
    const response = await create(); expect(response.status).toBe(201);
    const body = await response.json<{ id: string; creationKey: string }>(); expected.push(body.creationKey);
    expect((await h.request(`/v1/vms/${body.id}`, headers(), { method: "DELETE" })).status).toBe(204);
  }
  const before = h.upstreamRequests.length, found: string[] = [];
  let cursor: string | null = null;
  for (let n = 0; n < 3; n++) {
    const response = await history(`?limit=1${cursor === null ? "" : `&cursor=${cursor}`}`);
    expect(response.status).toBe(200);
    const page = await response.json<{ items: Array<{ creationKey: string; state: string }>; nextCursor: string | null }>();
    expect(page.items).toHaveLength(1); expect(page.items[0]!.state).toBe("deleted");
    found.push(page.items[0]!.creationKey); cursor = page.nextCursor;
    if (n < 2) expect(cursor).toMatch(/^[a-f0-9]{64}$/);
  }
  expect(cursor).toBeNull(); expect(found.sort()).toEqual(expected.sort());
  expect(h.upstreamRequests).toHaveLength(before);
  expect((await history("?limit=0")).status).toBe(400);
  expect((await history("?cursor=invalid")).status).toBe(400);
});

it("isolates service history, preserves handle discovery across key rotation and rechecks current labels", async () => {
  const service = await h.addServiceKey({ id: "driver", labels: { role: "cloud" } });
  const serviceHeaders = (credential: string) => ({ ...bearer(credential), "x-cmux-team-id": "team_alpha" });
  const response = await h.request("/v1/vms", serviceHeaders(service), { method: "POST", body: { labels: { role: "cloud" } } });
  expect(response.status).toBe(201);
  const { creationKey } = await response.json<{ creationKey: string }>();
  const rotated = await h.addServiceKey({ id: "driver", labels: { role: "cloud" } });
  const page = await h.request("/v1/vm-creations", serviceHeaders(rotated)); expect(page.status).toBe(200);
  expect(await page.json()).toMatchObject({ items: [{ creationKey, state: "committed" }] });
  const other = await h.addServiceKey({ id: "unrelated-driver", labels: { role: "cloud" } });
  const unrelated = await h.request("/v1/vm-creations", serviceHeaders(other));
  expect(await unrelated.json()).toEqual({ items: [], nextCursor: null });
  Object.assign(h.resources[0]!, { labels: { role: "unrelated" } });
  const hidden = await h.request("/v1/vm-creations", serviceHeaders(rotated));
  expect(await hidden.json()).toEqual({ items: [], nextCursor: null });
});

it("keeps caller-supplied keys private even when they resemble server handles", async () => {
  const supplied = "vcr_00000000000000000000000001";
  const response = await create(supplied); expect(response.status).toBe(201);
  expect(await response.json()).not.toHaveProperty("creationKey");
  const page = await history(); expect(await page.json()).toEqual({ items: [], nextCursor: null });
});

it("resumes an unkeyed fork's retained allocation after the source is deleted", async () => {
  await h.dispose(); h = await makeHarness({ maxVms: 2 }); token = await h.addKey("team_alpha", ["vm:read", "vm:write"]);
  const source = h.addVm("team_alpha"), body = { displayName: "forked agent" };
  h.upstream.fail("create", 429);
  const first = await h.request(`/v1/vms/${source.vmId}/fork`, headers(), { method: "POST", body });
  expect(first.status).toBe(503); const key = await handle(first);
  expect((await h.request(`/v1/vms/${source.vmId}`, headers(), { method: "DELETE" })).status).toBe(204);
  const page = await history(); expect(await page.json()).toMatchObject({ items: [{ creationKey: key, operation: "fork", sourceId: source.vmId }] });
  const resumed = await h.request(`/v1/vms/${source.vmId}/fork`, headers(key), { method: "POST", body });
  expect(resumed.status).toBe(201); expect(await resumed.json()).toMatchObject({ creationKey: key });
  expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  expect(allocations()).toHaveLength(2);
});

it("discovers a service fork's retained snapshot before VM admission and resumes it after source deletion", async () => {
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer())); let fail = true;
  await h.dispose(); h = await makeHarness({ maxVms: 2, limits: Layer.succeed(TenantLimits, { ...limits, advance: (tenant, key, progress) => {
    if (fail && progress.phase === "creating") { fail = false; return Effect.fail(new LimitsUnavailable({ cause: "intent write failed" })); }
    return limits.advance(tenant, key, progress);
  } }) });
  token = await h.addKey("team_alpha", ["vm:write"]);
  const source = h.addVm("team_alpha", "running", { role: "cloud" });
  const service = await h.addServiceKey({ id: "driver", labels: { role: "cloud" }, scopes: ["vm:read", "vm:write"] });
  const serviceHeaders = { ...bearer(service), "x-cmux-team-id": "team_alpha" }, body = { labels: { role: "cloud" } };
  const first = await h.request(`/v1/vms/${source.vmId}/fork`, serviceHeaders, { method: "POST", body });
  expect(first.status).toBe(503); const key = await handle(first);
  expect(allocations()).toHaveLength(0);
  const page = await h.request("/v1/vm-creations", serviceHeaders); expect(page.status).toBe(200);
  expect(await page.json()).toMatchObject({ items: [{ creationKey: key, state: "unresolved", id: null }] });
  expect((await h.request(`/v1/vms/${source.vmId}`, headers(), { method: "DELETE" })).status).toBe(204);
  const retry = await h.request(`/v1/vms/${source.vmId}/fork`, { ...serviceHeaders, "idempotency-key": key }, { method: "POST", body });
  expect(retry.status).toBe(201); expect(await retry.json()).toMatchObject({ creationKey: key });
  expect(h.upstream.callsTo("POST", /\/snapshot$/)).toHaveLength(1);
  expect(allocations()).toHaveLength(1);
});

it("frees an unkeyed create's slot when the provider definitely rejects it", async () => {
  h.upstream.fail("create", 429);
  expect((await create()).status).toBe(429);
  expect((await create()).status).toBe(201);
  expect(h.upstream.vms.size).toBe(1);
});
