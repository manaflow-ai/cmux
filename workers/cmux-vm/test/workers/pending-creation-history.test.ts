import { afterEach, beforeEach, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";
import { memoryLedgerStorage, TenantLedger, type LedgerStorage } from "../../src/limits/ledger.ts";
import { memoryLimitsLayer } from "../../src/limits/service.ts";
import { newVmCreationKey, newVmId } from "../../src/lib/ids.ts";
import { Effect, Layer } from "effect";
import { TenantLimits } from "../../src/limits/service.ts";

let h: Awaited<ReturnType<typeof makeHarness>>;
beforeEach(async () => { h = await makeHarness({ maxVms: 3 }); });
afterEach(async () => { await h.dispose(); });
const digest = async (value: unknown) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)))), b => b.toString(16).padStart(2, "0")).join("");

it("lists only pending server-issued creations without contacting the provider", async () => {
  const key = await h.addKey("team_alpha", ["vm:read", "vm:write"]), headers = bearer(key);
  expect((await h.request("/v1/vms", headers, { method: "POST", body: {} })).status).toBe(201);
  h.recordFault.before = 1;
  const failed = await h.request("/v1/vms", headers, { method: "POST", body: {} });
  expect(failed.status).toBe(503);
  const { creationKey } = await failed.json<{ creationKey: string }>();
  const before = h.upstreamRequests.length;
  const response = await h.request("/v1/vm-creations?state=pending", headers);
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ items: [{ creationKey, state: "pending" }], nextCursor: null, pendingIndex: "ready" });
  const all = await h.request("/v1/vm-creations", headers);
  expect((await all.json<{ items: unknown[] }>()).items).toHaveLength(2);
  expect(h.upstreamRequests).toHaveLength(before);
});

const seed = async (storage: LedgerStorage, createdAt: string, cursor: string) => {
  const ledger = new TenantLedger(storage), key = newVmCreationKey(), scoped = await digest(["key", key]), id = newVmId();
  const generated = { key, cursor, scope: "tenant", createdBy: "key:owner", createdAt, displayName: null, labels: {}, operation: "create" as const };
  await ledger.begin(scoped, "request", 0, undefined, generated);
  await ledger.reserve("vm", 3, 0, 0, cursor);
  await ledger.advance(scoped, { phase: "creating", vmId: id, reservationId: cursor, context: "context", createdBy: "key:owner",
    dispatch: { state: "sent", token: "send" }, intent: { receipt: { id, displayName: null, labels: {}, idleTimeoutSeconds: 300 },
      probe: { provider: "provider", environment: "local", request: "request" }, createdAt, floors: {} } }, 1);
  return { key, id, scoped, reservation: cursor };
};

it("pages pending work newest first, independently of the permanent history's digest order", async () => {
  await h.dispose();
  const storage = memoryLedgerStorage(); h = await makeHarness({ limits: memoryLimitsLayer(() => storage) });
  const older = await seed(storage, "2026-10-17T00:00:00Z", "1".repeat(64));
  const newer = await seed(storage, "2026-10-18T00:00:00Z", "f".repeat(64));
  const headers = bearer(await h.addKey("team_alpha", ["vm:read"]));
  const first = await h.request("/v1/vm-creations?state=pending&limit=1", headers);
  expect(first.status).toBe(200);
  const page = await first.json<{ items: Array<{ creationKey: string }>; nextCursor: string }>();
  expect(page.items.map(x => x.creationKey)).toEqual([newer.key]);
  expect(page.nextCursor).toMatch(/^p1_[a-f0-9]{16}-[a-f0-9]{64}$/);
  const second = await h.request(`/v1/vm-creations?state=pending&limit=1&cursor=${page.nextCursor}`, headers);
  expect(await second.json()).toMatchObject({ items: [{ creationKey: older.key }], nextCursor: null, pendingIndex: "ready" });
  expect(h.upstreamRequests).toHaveLength(0);
});

it("preserves service scope and current labels and never reveals private caller keys", async () => {
  const labels = { role: "cloud" }, service = await h.addServiceKey({ id: "pending-owner", labels });
  const headers = { ...bearer(service), "x-cmux-team-id": "team_alpha" };
  h.recordFault.before = 1;
  const response = await h.request("/v1/vms", headers, { method: "POST", body: { labels: { role: "cloud" } } });
  expect(response.status).toBe(503);
  const { creationKey } = await response.json<{ creationKey: string }>();
  const page = await h.request("/v1/vm-creations?state=pending", headers);
  expect(await page.json()).toMatchObject({ items: [{ creationKey }], pendingIndex: "ready" });
  const other = await h.addServiceKey({ id: "other-driver", labels: { role: "cloud" } });
  expect(await (await h.request("/v1/vm-creations?state=pending", { ...headers, ...bearer(other) })).json()).toEqual({ items: [], nextCursor: null, pendingIndex: "ready" });
  labels.role = "other";
  expect(await (await h.request("/v1/vm-creations?state=pending", headers)).json()).toEqual({ items: [], nextCursor: null, pendingIndex: "ready" });
  const member = bearer(await h.addKey("team_alpha", ["vm:read", "vm:write"]));
  h.recordFault.before = 1;
  expect((await h.request("/v1/vms", { ...member, "idempotency-key": "private-caller-key-never-return" }, { method: "POST", body: {} })).status).toBe(503);
  const own = await h.request("/v1/vm-creations?state=pending", member);
  expect(await own.json()).toEqual({ items: [], nextCursor: null, pendingIndex: "ready" });
  const limited = bearer(await h.addKey("team_alpha", ["vm:read"], { allowlist: [] }));
  expect((await h.request("/v1/vm-creations?state=pending", limited)).status).toBe(403);
  expect((await h.request(`/v1/vm-creations?state=pending&cursor=${"a".repeat(64)}`, member)).status).toBe(400);
  expect((await h.request(`/v1/vm-creations?cursor=p1_001fffffffffffff-${"a".repeat(64)}`, member)).status).toBe(400);
});

it("refuses an older limits object that silently ignores the pending selector", async () => {
  await h.dispose();
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  h = await makeHarness({ limits: Layer.succeed(TenantLimits, { ...limits,
    listGenerated: (tenant, scope, cursor, limit) => limits.listGenerated(tenant, scope, cursor, limit) }) });
  const headers = bearer(await h.addKey("team_alpha", ["vm:read"]));
  expect((await h.request("/v1/vm-creations?state=pending", headers)).status).toBe(503);
});

it("backfills older retained slots in bounded steps before claiming complete pending history", async () => {
  await h.dispose();
  const storage = memoryLedgerStorage(); h = await makeHarness({ limits: memoryLimitsLayer(() => storage) });
  const pending = await seed(storage, "2026-10-18T00:00:00Z", "e".repeat(64));
  const held = await storage.get(`reserve:${pending.reservation}`);
  if (typeof held !== "object" || held === null) throw Error("missing fixture reservation");
  await storage.put(`reserve:${pending.reservation}`, Object.fromEntries(Object.entries(held).filter(([key]) => key !== "vmCreation")));
  for (let n = 0; n < 70; n++) await storage.put(`idem:000-${n.toString().padStart(3, "0")}`, { old: "private-client-key-not-a-public-handle" });
  const headers = bearer(await h.addKey("team_alpha", ["vm:read"]));
  const first = await h.request("/v1/vm-creations?state=pending", headers);
  expect(first.status).toBe(200);
  const building = await first.json<{ pendingIndex: string; nextCursor: string }>();
  expect(building.pendingIndex).toBe("building");
  expect(building.nextCursor).toMatch(/^i1_[a-f0-9]{32}$/);
  expect(JSON.stringify(building)).not.toContain("private-client-key");
  const ready = await h.request(`/v1/vm-creations?state=pending&cursor=${building.nextCursor}`, headers);
  expect(await ready.json()).toMatchObject({ items: [{ creationKey: pending.key }], pendingIndex: "ready", nextCursor: null });
  expect(h.upstreamRequests).toHaveLength(0);
});
