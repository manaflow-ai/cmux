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
});
