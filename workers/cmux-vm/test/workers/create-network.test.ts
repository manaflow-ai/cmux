/** VM creation must keep network intent, permission checks and retries together. */
import { afterEach, describe, expect, it } from "vitest";
import { bearer } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TENANT = "team_alpha";
let current: Harness | undefined;
const harness = async (options?: HarnessOptions) => {
  current = await makeHarness(options);
  return current;
};
afterEach(async () => {
  await current?.dispose();
  current = undefined;
});

const create = (t: Harness, key: string, body: unknown, requestKey?: string) =>
  t.request("/v1/vms", { ...bearer(key), ...(requestKey === undefined ? {} : { "Idempotency-Key": requestKey }) }, { method: "POST", body });
const networkKey = (t: Harness) => t.addKey(TENANT, ["vm:write", "vm:network"]);

describe("initial VM network policy", () => {
  it("keeps the existing no-network default with the ordinary create scope", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write"]);

    const response = await create(t, key, {});
    expect(response.status).toBe(201);
    expect(await response.json()).not.toHaveProperty("initialNetwork");
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ firewall: { rules: [] } });
  });

  it("applies explicit public egress only to the newly created VM", async () => {
    const t = await harness();
    const key = await networkKey(t);

    const response = await create(t, key, { initialNetwork: { publicEgress: true } });
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ initialNetwork: { publicEgress: true, httpsProxyHosts: [] } });
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({
      firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] },
    });
  });

  it("requires a separate network scope before creating anything", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write"]);

    expect((await create(t, key, { initialNetwork: { publicEgress: true } })).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
    expect(t.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it("refuses malformed network intent rather than silently discarding it", async () => {
    const t = await harness();
    const key = await networkKey(t);

    expect((await create(t, key, { initialNetwork: { publicEgress: "true" } })).status).toBe(400);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("refuses a proxy destination that the deployment has not enabled", async () => {
    const t = await harness();
    const key = await networkKey(t);
    const response = await create(t, key, {
      initialNetwork: {
        httpsProxies: [{ hostname: "api.example.test", destination: "https://not-enabled.example.test", headers: { authorization: "Bearer proxy-fixture-secret" } }],
      },
    });

    expect(response.status).toBe(400);
    expect(await response.text()).not.toContain("proxy-fixture-secret");
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("does not replay a private create when the same key now asks for egress", async () => {
    const t = await harness();
    const key = await networkKey(t);

    expect((await create(t, key, {}, "create-network-same-request")).status).toBe(201);
    expect((await create(t, key, { initialNetwork: { publicEgress: true } }, "create-network-same-request")).status).toBe(409);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  });

  it("does not treat execution permission as network permission", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write", "vm:exec"]);
    expect((await create(t, key, { initialNetwork: { publicEgress: true } })).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("still requires VM creation permission with a network scope", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:network"]);
    expect((await create(t, key, { initialNetwork: {} })).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("keeps the service's required labels when authorizing network intent", async () => {
    const t = await harness();
    const key = await t.addServiceKey({ scopes: ["vm:write", "vm:network"] });
    const headers = { ...bearer(key), "x-cmux-team-id": TENANT };
    const initialNetwork = { publicEgress: true };
    expect((await t.request("/v1/vms", headers, { method: "POST", body: { initialNetwork } })).status).toBe(403);
    expect(t.upstreamRequests).toHaveLength(0);
    const response = await t.request("/v1/vms", headers, { method: "POST", body: { initialNetwork, labels: { role: "chief" } } });
    expect(response.status).toBe(201);
    expect(t.audit).toContainEqual(expect.objectContaining({ tenantId: TENANT, actor: "service:cloud-chief", outcome: "ok" }));
  });
});

const ORIGIN = "https://coderouter.example.test";
const HOSTNAME = "coderouter.cmux.internal";
const SECRET = "Bearer proxy-fixture-secret";
const proxyBody = (secret = SECRET) => ({
  initialNetwork: {
    publicEgress: true,
    httpsProxies: [{ hostname: HOSTNAME, destination: ORIGIN, headers: { "X-Chatmux-Vm-Authorization": secret } }],
  },
});

describe("creation HTTPS proxies", () => {
  it("installs an approved proxy inline, with this new VM as its only source", async () => {
    const t = await harness({ httpsProxyOrigins: [ORIGIN] });
    const other = t.addVm("team_bravo");
    const key = await networkKey(t);
    const response = await create(t, key, proxyBody());
    expect(response.status).toBe(201);
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({ initialNetwork: { publicEgress: true, httpsProxyHosts: [HOSTNAME] } });
    expect(text).not.toContain(SECRET);
    expect(text).not.toContain(ORIGIN);
    expect(JSON.stringify(t.resources)).not.toContain(SECRET);
    expect(JSON.stringify(t.audit)).not.toContain(SECRET);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({
      tls: { rules: [{ action: "allow", domain: HOSTNAME, source: {}, destination: { host: "coderouter.example.test", port: 443 },
        transform: [{ headers: { "x-chatmux-vm-authorization": SECRET } }] }] },
    });
    expect(t.upstream.callsTo("PUT", /./)).toHaveLength(0);
    expect(t.isDeleted(other.vmId)).toBe(false);
  });

  it("replays the same policy but refuses a changed secret under the same key", async () => {
    const t = await harness({ httpsProxyOrigins: [ORIGIN] });
    const key = await networkKey(t);
    const first = await create(t, key, proxyBody(), "proxy-create-request");
    const again = await create(t, key, proxyBody(), "proxy-create-request");
    expect(first.status).toBe(201);
    expect(again.status).toBe(201);
    expect(await again.json()).toEqual(await first.json());
    const changed = await create(t, key, proxyBody("Bearer changed-fixture-secret"), "proxy-create-request");
    expect(changed.status).toBe(409);
    expect(await changed.text()).not.toContain("changed-fixture-secret");
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  });

  it("does not expose a proxy credential echoed by a failed provider", async () => {
    const t = await harness({ httpsProxyOrigins: [ORIGIN] });
    const key = await networkKey(t);
    t.upstream.fail("create", 503, 1, { message: SECRET });
    const response = await create(t, key, proxyBody());
    expect(response.status).toBe(503);
    expect(await response.text()).not.toContain(SECRET);
    expect(JSON.stringify(t.audit)).not.toContain(SECRET);
    expect(t.resources.filter((row) => row.kind === "vm")).toHaveLength(0);
  });

  it.each([
    { authorization: { nested: SECRET } },
    { authorization: `${SECRET}\r\nInjected: value` },
    { authorization: `${SECRET}\n` },
    { "authorization\n": SECRET },
    { host: SECRET },
    { authorization: SECRET, Authorization: SECRET },
  ])("refuses invalid secret headers without reflecting them", async (headers) => {
    const t = await harness({ httpsProxyOrigins: [ORIGIN] });
    const key = await networkKey(t);
    const response = await create(t, key, { initialNetwork: { httpsProxies: [{ hostname: HOSTNAME, destination: ORIGIN, headers }] } });
    expect(response.status).toBe(400);
    expect(await response.text()).not.toContain(SECRET);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("rejects a caller-selected source or duplicate hostname before any provider call", async () => {
    const t = await harness({ httpsProxyOrigins: [ORIGIN] });
    const key = await networkKey(t);
    const proxy = proxyBody().initialNetwork.httpsProxies[0];
    for (const httpsProxies of [[{ ...proxy, source: { vmId: "another-tenant-vm" } }], [proxy, { ...proxy, hostname: HOSTNAME.toUpperCase() }]]) {
      const response = await create(t, key, { initialNetwork: { httpsProxies } });
      expect(response.status).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it.each(["http://coderouter.example.test", `${ORIGIN}/path`, `${ORIGIN}.attacker.test`, `https://user@coderouter.example.test`])(
    "refuses a destination outside the exact enabled origin", async (destination) => {
      const t = await harness({ httpsProxyOrigins: [ORIGIN] });
      const key = await networkKey(t);
      const response = await create(t, key, { initialNetwork: { httpsProxies: [{ hostname: HOSTNAME, destination }] } });
      expect(response.status).toBe(400);
      expect(t.upstreamRequests).toHaveLength(0);
    },
  );

  it("bounds proxy count and header sizes before creating a VM", async () => {
    const t = await harness({ httpsProxyOrigins: [ORIGIN] });
    const key = await networkKey(t);
    const tooMany = Array.from({ length: 9 }, (_, index) => ({ hostname: `api${index}.example.test`, destination: ORIGIN }));
    const tooLarge = [{ hostname: HOSTNAME, destination: ORIGIN, headers: { authorization: "x".repeat(4097) } }];
    for (const httpsProxies of [tooMany, tooLarge]) {
      expect((await create(t, key, { initialNetwork: { httpsProxies } })).status).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });
});
