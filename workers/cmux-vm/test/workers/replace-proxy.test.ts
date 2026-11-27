/** Credential rotation may replace only a rule whose exact source is the owned VM. */
import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const ORIGIN = "https://coderouter.example.test";
const HOST = "coderouter.cmux.internal";
const SECRET = "Bearer replacement-fixture-secret";
let current: Harness | undefined;
const harness = async () => {
  current = await makeHarness({ httpsProxyOrigins: [ORIGIN] });
  return current;
};
afterEach(async () => { await current?.dispose(); current = undefined; });

const replace = (t: Harness, vm: string, key: string, headers: unknown = { authorization: SECRET }, retryKey?: string) =>
  t.request(`/v1/vms/${vm}/https-proxies/${HOST}`, { ...bearer(key), ...(retryKey === undefined ? {} : { "Idempotency-Key": retryKey }) },
    { method: "PUT", body: { destination: ORIGIN, headers } });
const rule = (id: string, vmId: string) => ({ id, action: "allow", protocol: "http", domain: HOST, source: { vmId },
  destination: { host: "coderouter.example.test", port: 443 }, transform: [{ headers: { authorization: "***" } }] });

describe("existing VM HTTPS proxy replacement", () => {
  it("rotates the inline rule after creation and ignores unrelated shared-account rules", async () => {
    const t = await harness();
    const key = await t.addKey("team_alpha", ["vm:write", "vm:network"]);
    const created = await t.request("/v1/vms", bearer(key), { method: "POST", body: {
      initialNetwork: { httpsProxies: [{ hostname: HOST, destination: ORIGIN, headers: { authorization: "Bearer original-fixture" } }] },
    } });
    expect(created.status).toBe(201);
    const vm = await created.json<{ id: string }>();
    const original = [...t.upstream.tlsRules.entries()][0];
    expect(original).toBeDefined();
    const owned = original?.[1];
    t.upstream.tlsRules.set("unrelated", rule("unrelated", "other-tenant-provider-vm"));
    const response = await replace(t, vm.id, key);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: vm.id, hostname: HOST });
    expect(t.upstream.callsTo("PUT", /^\/v5\/tls\//)).toMatchObject([{ path: `/v5/tls/${original?.[0]}`, json: {
      source: owned?.source, transform: [{ headers: { authorization: SECRET } }],
    } }]);
    expect(t.upstream.tlsRules.get("unrelated")).toEqual(rule("unrelated", "other-tenant-provider-vm"));
    expect(JSON.stringify(t.audit)).not.toContain(SECRET);
    expect(JSON.stringify(t.resources)).not.toContain(SECRET);
  });

  it("requires network permission before reading provider rules", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:write"]);
    expect((await replace(t, vm.vmId, key)).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("keeps another tenant's VM hidden without a provider request", async () => {
    const t = await harness();
    const vm = t.addVm("team_bravo");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    expect((await replace(t, vm.vmId, key)).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("refuses missing exact-VM rules instead of creating one", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("shared", { ...rule("shared", "other-vm"), source: { vpcId: "shared-network" } });
    expect((await replace(t, vm.vmId, key)).status).toBe(404);
    expect(t.upstream.callsTo("GET", /^\/v5\/tls$/)).toHaveLength(1);
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(0);
    expect(t.upstream.callsTo("POST", /./)).toHaveLength(0);
  });

  it("never reflects malformed credentials in schema errors", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    const response = await replace(t, vm.vmId, key, { authorization: { nested: SECRET } });
    expect(response.status).toBe(400);
    expect(await response.text()).not.toContain(SECRET);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("allows a network-only key and replaces credentials without returning them", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("owned", rule("owned", vm.upstreamId));
    const response = await replace(t, vm.vmId, key);
    expect(response.status).toBe(200);
    const body = await response.text();
    expect(body).not.toContain(SECRET);
    expect(body).not.toContain(vm.upstreamId);
    expect(body).not.toContain(ORIGIN);
    expect(JSON.stringify(t.audit)).not.toContain(SECRET);
  });

  it.each([
    { public: true }, { vmId: "other-vm" }, { vpcId: "shared-network" },
    { vmId: "OWN", vpcId: "shared-network" }, { vmId: "OWN", public: true }, { vmId: "OWN", extraSelector: true },
  ])("never rewrites a rule with a broader or foreign source", async (source) => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    const exactSource = Object.fromEntries(Object.entries(source).map(([name, value]) => [name, value === "OWN" ? vm.upstreamId : value]));
    t.upstream.tlsRules.set("not-owned", { ...rule("not-owned", vm.upstreamId), source: exactSource });
    expect((await replace(t, vm.vmId, key)).status).toBe(404);
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(0);
  });

  it("refuses multiple exact-source matches without choosing a winner", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("first", rule("first", vm.upstreamId));
    t.upstream.tlsRules.set("second", rule("second", vm.upstreamId));
    expect((await replace(t, vm.vmId, key)).status).toBe(409);
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(0);
  });

  it("finds the owned rule on a later bounded page", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    for (let index = 0; index < 64; index++) t.upstream.tlsRules.set(`foreign-${index}`, rule(`foreign-${index}`, "other-vm"));
    t.upstream.tlsRules.set("owned", rule("owned", vm.upstreamId));
    expect((await replace(t, vm.vmId, key)).status).toBe(200);
    expect(t.upstream.callsTo("GET", /^\/v5\/tls$/).map((call) => call.search.get("offset"))).toEqual(["0", "64"]);
    expect(t.upstream.callsTo("PUT", /^\/v5\/tls\/owned$/)).toHaveLength(1);
  });

  it("refuses an over-limit listing without partially updating it", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    for (let index = 0; index < 257; index++) t.upstream.tlsRules.set(`rule-${index}`, rule(`rule-${index}`, vm.upstreamId));
    expect((await replace(t, vm.vmId, key)).status).toBe(503);
    expect(t.upstream.callsTo("GET", /^\/v5\/tls$/)).toHaveLength(1);
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(0);
  });

  it("keeps stale retries from overwriting a later rotation", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("owned", rule("owned", vm.upstreamId));
    expect((await replace(t, vm.vmId, key, { authorization: SECRET }, "first-rotation")).status).toBe(200);
    expect((await replace(t, vm.vmId, key, { authorization: "Bearer later-fixture" }, "second-rotation")).status).toBe(200);
    expect((await replace(t, vm.vmId, key, { authorization: SECRET }, "first-rotation")).status).toBe(200);
    expect((await replace(t, vm.vmId, key, { authorization: "Bearer changed-fixture" }, "first-rotation")).status).toBe(409);
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(2);
    expect(t.upstream.tlsRules.get("owned")).toMatchObject({ transform: [{ headers: { authorization: "Bearer later-fixture" } }] });
  });

  it("sanitizes a provider error that echoes the replacement credentials", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("owned", rule("owned", vm.upstreamId));
    t.upstream.fail("replaceTlsRule", 503, 1, { message: SECRET });
    const response = await replace(t, vm.vmId, key);
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain(SECRET);
    expect(JSON.stringify(t.audit)).not.toContain(SECRET);
  });

  it("cannot reach a same-tenant VM outside a key's resource allowlist", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const allowed = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"], { allowlist: [allowed.vmId] });
    expect((await replace(t, vm.vmId, key)).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("keeps service labels authoritative with network permission", async () => {
    const t = await harness();
    const key = await t.addServiceKey({ scopes: ["vm:network"] });
    const headers = { ...bearer(key), "x-cmux-team-id": "team_alpha" };
    const other = t.addVm("team_alpha", "running", { role: "dev" });
    const call = (vm: string) => t.request(`/v1/vms/${vm}/https-proxies/${HOST}`, headers,
      { method: "PUT", body: { destination: ORIGIN, headers: { authorization: SECRET } } });
    expect((await call(other.vmId)).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(0);
    const chief = t.addVm("team_alpha", "running", { role: "chief" });
    t.upstream.tlsRules.set("chief", rule("chief", chief.upstreamId));
    expect((await call(chief.vmId)).status).toBe(200);
    expect(t.audit).toContainEqual(expect.objectContaining({ actor: "service:cloud-chief", cmuxId: chief.vmId, outcome: "ok" }));
  });

  it("refuses a destination outside deployment policy before reading rules", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    const response = await t.request(`/v1/vms/${vm.vmId}/https-proxies/${HOST}`, bearer(key),
      { method: "PUT", body: { destination: `${ORIGIN}.attacker.test`, headers: { authorization: SECRET } } });
    expect(response.status).toBe(400);
    expect(await response.text()).not.toContain(SECRET);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("rejects an upstream rule id that would change the request path", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("..", rule("..", vm.upstreamId));
    expect((await replace(t, vm.vmId, key)).status).toBe(503);
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(0);
  });

  it("clears the old header set when the replacement omits headers", async () => {
    const t = await harness();
    const vm = t.addVm("team_alpha");
    const key = await t.addKey("team_alpha", ["vm:network"]);
    t.upstream.tlsRules.set("owned", rule("owned", vm.upstreamId));
    const response = await t.request(`/v1/vms/${vm.vmId}/https-proxies/${HOST}`, bearer(key), { method: "PUT", body: { destination: ORIGIN } });
    expect(response.status).toBe(200);
    expect(t.upstream.tlsRules.get("owned")).toMatchObject({ transform: [{ headers: {} }] });
  });
});
