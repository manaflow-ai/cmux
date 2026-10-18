/** VM creation must keep network intent, permission checks and retries together. */
import { afterEach, describe, expect, it } from "vitest";
import { SESSION_SCOPES } from "../../src/domain/scopes.ts";
import { bearer } from "../support/endpoints.ts";
import { makeHarness } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TENANT = "team_alpha";
let current: Harness | undefined;
const harness = async () => {
  current = await makeHarness();
  return current;
};
afterEach(async () => {
  await current?.dispose();
  current = undefined;
});

const create = (t: Harness, key: string, body: unknown, requestKey?: string) =>
  t.request("/v1/vms", { ...bearer(key), ...(requestKey === undefined ? {} : { "Idempotency-Key": requestKey }) }, { method: "POST", body });

describe("initial VM network policy", () => {
  it("keeps the existing no-network default with the ordinary create scope", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, ["vm:write"]);

    expect((await create(t, key, {})).status).toBe(201);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)[0]?.json).toMatchObject({ firewall: { rules: [] } });
  });

  it("applies explicit public egress only to the newly created VM", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, [...SESSION_SCOPES]);

    expect((await create(t, key, { initialNetwork: { publicEgress: true } })).status).toBe(201);
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
    const key = await t.addKey(TENANT, [...SESSION_SCOPES]);

    expect((await create(t, key, { initialNetwork: { publicEgress: "true" } })).status).toBe(400);
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("refuses a proxy destination that the deployment has not enabled", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT, [...SESSION_SCOPES]);
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
    const key = await t.addKey(TENANT, [...SESSION_SCOPES]);

    expect((await create(t, key, {}, "create-network-same-request")).status).toBe(201);
    expect((await create(t, key, { initialNetwork: { publicEgress: true } }, "create-network-same-request")).status).toBe(409);
    expect(t.upstream.callsTo("POST", /^\/v5\/vms$/)).toHaveLength(1);
  });
});
