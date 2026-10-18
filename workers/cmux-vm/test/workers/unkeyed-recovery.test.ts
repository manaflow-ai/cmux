import { afterEach, beforeEach, expect, it } from "vitest";
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
