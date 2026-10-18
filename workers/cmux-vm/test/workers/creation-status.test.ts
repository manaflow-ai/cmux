import { Effect, Layer } from "effect";
import { afterEach, expect, it } from "vitest";
import { memoryLimitsLayer, TenantLimits } from "../../src/limits/service.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
let current: Harness | undefined;
afterEach(async () => { await current?.dispose(); current = undefined; });
const KEY = "creation-status-intent";
const harness = async (options: HarnessOptions = {}) => { current = await makeHarness(options); return current; };
const setup = async (options: HarnessOptions = {}) => {
  const t = await harness(options), snapshot = t.upstream.addSnapshot("baked-image");
  t.setBootImages(JSON.stringify([{ id: "team-agent", revision: "v1", displayName: "Team agent", snapshotId: snapshot.id, services: ["team-vm"] }]));
  const token = await t.addServiceKey({ id: "team-vm", labels: { role: "team-vm" }, scopes: ["vm:read", "vm:write", "vm:network"] });
  const headers = (key = token, tenant = "team_alpha") => ({ authorization: `Bearer ${key}`, "x-cmux-team-id": tenant, "idempotency-key": KEY });
  const create = () => t.request("/v1/vms", headers(), { method: "POST", body: { displayName: "persistent team", labels: { role: "team-vm", cmux_next_team: "logical-team" }, image: { id: "team-agent", revision: "v1" }, idleTimeoutSeconds: 300, initialNetwork: { publicEgress: true } } });
  const status = (key = token, tenant = "team_alpha") => t.request("/v1/vm-creations/by-key", headers(key, tenant));
  const reconcile = (key = token, tenant = "team_alpha") => t.request("/v1/vm-creations/by-key/reconcile", headers(key, tenant), { method: "POST" });
  return { ...t, token, create, status, reconcile, headers };
};

it("reports a retained create without provider I/O, then reconciles the same VM without creating, waking or growing it", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const before = t.upstreamRequests.length;
  const pending = await t.status(); expect(pending.status).toBe(200);
  expect(await pending.json()).toMatchObject({ state: "pending" });
  expect(t.upstreamRequests).toHaveLength(before);
  t.setBilling("team_alpha", false);
  t.setBootImages("[]");
  const resolved = await t.reconcile(); expect(resolved.status).toBe(200);
  expect(await resolved.json()).toMatchObject({ state: "committed", receipt: { displayName: "persistent team", labels: { role: "team-vm" }, idleTimeoutSeconds: 300, bootImage: { id: "team-agent", revision: "v1" }, initialNetwork: { publicEgress: true, httpsProxyHosts: [] } } });
  expect(t.resources.filter((r) => r.kind === "vm")).toHaveLength(1);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  expect(t.upstreamRequests.slice(before).every((r) => r.method === "GET")).toBe(true);
  expect(t.audit.some((r) => r.action === "vm.create.reconcile" && r.outcome === "ok")).toBe(true);
});

it("preserves the committed creation receipt after the limits journal is gone and reports deletion without resurrection", async () => {
  const limits = await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer()));
  const t = await setup({ limits: Layer.succeed(TenantLimits, limits) });
  const created = await t.create(); expect(created.status).toBe(201);
  const receipt: unknown = await created.json();
  Object.assign(limits, await Effect.runPromise(Effect.provide(TenantLimits, memoryLimitsLayer())));
  const status = await t.status(); expect(status.status).toBe(200);
  expect(await status.json()).toMatchObject({ state: "committed", receipt: expect.objectContaining({ bootImage: { id: "team-agent", revision: "v1", displayName: "Team agent" } }) });
  expect(typeof receipt === "object" && receipt !== null && "id" in receipt && typeof receipt.id === "string").toBe(true);
  if (typeof receipt !== "object" || receipt === null || !("id" in receipt) || typeof receipt.id !== "string") throw Error("missing VM id");
  expect((await t.request(`/v1/vms/${receipt.id}`, t.headers(), { method: "DELETE" })).status).toBe(204);
  expect(await (await t.status()).json()).toMatchObject({ state: "deleted", id: receipt.id });
  expect(await (await t.reconcile()).json()).toMatchObject({ state: "deleted", id: receipt.id });
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
});

it("keeps scope, tenant, service actor, label and allowlist checks ahead of provider reconciliation", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const readOnly = await t.addServiceKey({ id: "team-vm", labels: { role: "team-vm" }, scopes: ["vm:read"] });
  const otherService = await t.addServiceKey({ id: "another-service", labels: { role: "team-vm" } });
  const changedLabels = await t.addServiceKey({ id: "team-vm", labels: { role: "other" } });
  const restricted = await t.addKey("team_alpha", ["vm:read", "vm:write"], { allowlist: [] });
  const before = t.upstreamRequests.length;
  expect((await t.reconcile(readOnly)).status).toBe(403);
  for (const token of [otherService, changedLabels, restricted]) {
    expect((await t.status(token)).status).toBe(404);
    expect((await t.reconcile(token)).status).toBe(404);
  }
  expect((await t.status(t.token, "team_bravo")).status).toBe(404);
  expect(t.upstreamRequests).toHaveLength(before);
});

it("can reconcile through a rotated service key while retaining the original service identity", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const rotated = await t.addServiceKey({ id: "team-vm", labels: { role: "team-vm" }, scopes: ["vm:read", "vm:write"] });
  expect((await t.reconcile(rotated)).status).toBe(200);
  expect(t.resources[0]?.createdBy).toBe("service:team-vm");
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
});

it("keeps an absent or conflicting provider result pending instead of allocating a replacement", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const machine = [...t.upstream.vms.values()][0]!;
  machine.metadata["cmux_tenant"] = "team_bravo";
  expect((await t.reconcile()).status).toBe(503);
  t.upstream.vms.clear();
  const absent = await t.reconcile(); expect(absent.status).toBe(200);
  expect(await absent.json()).toMatchObject({ state: "pending" });
  expect(t.resources).toHaveLength(0);
  expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
});

it("refuses a changed provider context before sending a reconciliation request", async () => {
  const t = await setup(); t.recordFault.before = 1;
  expect((await t.create()).status).toBe(503);
  const before = t.upstreamRequests.length;
  t.setProviderConfig("https://changed-provider.test", "changed-test-key");
  expect((await t.reconcile()).status).toBe(503);
  expect(t.upstreamRequests).toHaveLength(before);
});
