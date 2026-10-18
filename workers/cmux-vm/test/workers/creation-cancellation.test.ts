import { afterEach, expect, it } from "vitest";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let h: Harness | undefined;
afterEach(async () => { await h?.dispose(); h = undefined; });
const KEY = "cancel-original-create";
const setup = async () => {
  h = await makeHarness({ maxVms: 1 });
  const t = h, token = await t.addKey("team_alpha", ["vm:read", "vm:write"]);
  const headers = { authorization: `Bearer ${token}`, "idempotency-key": KEY };
  const create = (key = KEY, resources?: { readonly vcpus: number }) => t.request("/v1/vms", { ...headers, "idempotency-key": key }, { method: "POST", body: { displayName: "cancelled team allocation", labels: { role: "team-vm" }, ...(resources === undefined ? {} : { resources }) } });
  const status = () => t.request("/v1/vm-creations/by-key", headers);
  const cancel = () => t.request("/v1/vm-creations/by-key/cancel", headers, { method: "POST" });
  const reconcile = () => t.request("/v1/vm-creations/by-key/reconcile", headers, { method: "POST" });
  return { ...t, create, status, cancel, reconcile, headers };
};
const gate = () => { let release = () => {}; const promise = new Promise<void>((resolve) => { release = resolve; }); return { promise, release }; };

it("cancels a retained allocation, keeps its tombstone, and frees quota without replaying create", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const cancelled = await t.cancel(); expect(cancelled.status).toBe(200);
  expect(await cancelled.json()).toMatchObject({ state: "cancelled" });
  expect(t.upstream.vms.size).toBe(0);
  expect(t.resources).toHaveLength(1);
  expect(t.isDeleted(t.resources[0]!.cmuxId)).toBe(true);
  expect(await (await t.status()).json()).toMatchObject({ state: "cancelled" });
  expect(await (await t.reconcile()).json()).toMatchObject({ state: "cancelled" });
  expect((await t.create()).status).toBe(409);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  expect((await t.create("fresh-intent")).status).toBe(201);
  expect(t.audit.some((r) => r.action === "vm.create.cancel" && r.outcome === "ok")).toBe(true);
});

it("fences a create paused before provider send without ever sending it", async () => {
  const t = await setup(), entered = gate(), resume = gate(), upstream = t.upstream.fetch;
  let waiting = true;
  t.upstream.fetch = async (request) => {
    if (waiting && request.method === "GET" && new URL(request.url).pathname.startsWith("/v5/vms/")) { waiting = false; entered.release(); await resume.promise; }
    return upstream(request);
  };
  const original = t.create(); await entered.promise;
  try {
    const cancelled = await t.cancel(); expect(cancelled.status).toBe(200);
    expect(await cancelled.json()).toMatchObject({ state: "cancelled" });
  } finally { resume.release(); await original; }
  expect((await original).status).not.toBe(201);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(0);
  expect((await t.create()).status).toBe(409);
});

it("retains an in-flight cancellation until its late allocation can be verified and deleted", async () => {
  const t = await setup(), entered = gate(), resume = gate(), upstream = t.upstream.fetch;
  t.upstream.fetch = async (request) => {
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms") { entered.release(); await resume.promise; }
    return upstream(request);
  };
  const original = t.create(); await entered.promise;
  try {
    const response = await t.cancel(); expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ state: "cancelling" });
    expect((await t.create()).status).toBe(409);
    expect((await t.create("different-intent")).status).toBe(429);
  } finally { resume.release(); await original; }
  expect((await original).status).not.toBe(201);
  expect(await (await t.reconcile()).json()).toMatchObject({ state: "cancelled" });
  expect(t.upstream.vms.size).toBe(0);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
});

it("never resends an uncertain provider create or reports a 404 as cancellation", async () => {
  const t = await setup(), upstream = t.upstream.fetch; let sends = 0;
  t.upstream.fetch = async (request) => {
    if (request.method === "POST" && new URL(request.url).pathname === "/v5/vms") { sends++; throw new TypeError("unknown provider outcome"); }
    return upstream(request);
  };
  expect((await t.create()).status).toBe(503);
  const cancellation = await t.cancel(); expect(cancellation.status).toBe(200);
  expect(await cancellation.json()).toMatchObject({ state: "cancelling" });
  expect((await t.create()).status).toBe(409);
  expect(await (await t.reconcile()).json()).toMatchObject({ state: "cancelling" });
  expect((await t.create("replacement")).status).toBe(429);
  expect(sends).toBe(1);
});

it("repairs a lost deletion reply against the same recorded allocation", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const upstream = t.upstream.fetch; let lose = true;
  t.upstream.fetch = async (request) => {
    const response = await upstream(request);
    if (lose && request.method === "DELETE") { lose = false; throw new TypeError("lost delete reply"); }
    return response;
  };
  expect((await t.cancel()).status).toBe(503);
  expect(t.upstream.vms.size).toBe(0);
  expect(await (await t.cancel()).json()).toMatchObject({ state: "cancelled" });
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
});

it("does not delete a completed creation and refuses callers without write permission", async () => {
  const t = await setup(); expect((await t.create()).status).toBe(201);
  const key = await t.addKey("team_alpha", ["vm:read"]);
  expect((await t.request("/v1/vm-creations/by-key/cancel", { ...t.headers, authorization: `Bearer ${key}` }, { method: "POST" })).status).toBe(403);
  expect((await t.cancel()).status).toBe(409);
  expect(t.upstream.callsTo("DELETE", /^\/v5\/vms\//)).toHaveLength(0);
  expect(t.upstream.vms.size).toBe(1);
});

it("deletes an unfinished allocation without growing it to the requested floors", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create(KEY, { vcpus: 8 })).status).toBe(503);
  [...t.upstream.vms.values()][0]!.resources.cpu = 4;
  const before = t.upstreamRequests.length;
  expect(await (await t.cancel()).json()).toMatchObject({ state: "cancelled" });
  expect(t.upstreamRequests.slice(before).every((r) => r.method === "GET" || r.method === "DELETE")).toBe(true);
  expect(t.upstream.vms.size).toBe(0);
});
