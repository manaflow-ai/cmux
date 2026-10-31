/**
 * Domains, verifications, certificates, TLS rules and forward-auth checks
 * (cx-b4h.6): every route is tenant-scoped (another tenant's id is 404 and
 * absent from lists, with no provider request), scope-checked before anything
 * else, closed to service and agent keys, and a tenant routes only names it
 * may: a managed hostname of its own or a domain it verified.
 */
import { Effect } from "effect";
import { afterEach, describe, expect, it } from "vitest";
import { StoreError } from "../../src/db/sql.ts";
import { DOMAIN_LIMITS } from "../../src/handlers/domains.ts";
import { ALL_SCOPES, allScopesExcept, bearer, DOMAIN_ENDPOINTS } from "../support/endpoints.ts";
import { makeHarness, type HarnessOptions } from "../support/harness.ts";

type Harness = Awaited<ReturnType<typeof makeHarness>>;
const TENANT_A = "team_alpha";
const TENANT_B = "team_bravo";
const ORIGIN = "https://api.example.test";
const SECRET = "Bearer domain-fixture-secret";
const ZONE = "vm.cmux.test";

let current: Harness | undefined;
const harness = async (options: HarnessOptions = {}) => {
  current = await makeHarness({ httpsProxyOrigins: [ORIGIN], domains: { managedZone: ZONE, edgeHost: "edge.cmux.test", certificateNameserver: "ns.cmux.test" }, ...options });
  return current;
};
afterEach(async () => {
  await current?.dispose();
  current = undefined;
});

interface Verification { readonly id: string; readonly domain: string; readonly state: string; readonly record: { readonly name: string; readonly value: string } }
interface DomainView { readonly id: string; readonly domain: string }
interface RuleView { readonly id: string; readonly domain: string; readonly headerNames: ReadonlyArray<string>; readonly destination: { readonly vmId?: string } }
interface ForwardAuthView { readonly id: string; readonly headerNames: ReadonlyArray<string> }

const send = (t: Harness, key: string, method: string, path: string, body?: unknown) => t.request(path, bearer(key), body === undefined ? { method } : { method, body });

const verifyOwn = async (t: Harness, key: string, domain: string): Promise<DomainView> => {
  const created = await send(t, key, "POST", "/v1/domain-verifications", { domain });
  expect(created.status).toBe(201);
  const verification = await created.json<Verification>();
  t.domains.publishTxt(verification.record.name, verification.record.value);
  const verified = await send(t, key, "POST", `/v1/domain-verifications/${verification.id}/verify`);
  expect(verified.status).toBe(200);
  return verified.json<DomainView>();
};

const ingress = (domain: string, vmId: string, extra: Record<string, unknown> = {}) => ({ domain, source: { public: true }, destination: { vmId, port: 3000 }, ...extra });

/** Tenant A with one of each resource; returns the ids. */
const fixtures = async (t: Harness) => {
  const key = await t.addKey(TENANT_A, ALL_SCOPES);
  const domain = await verifyOwn(t, key, "example.com");
  const pending = await (await send(t, key, "POST", "/v1/domain-verifications", { domain: "pending.test" })).json<Verification>();
  const vm = t.addVm(TENANT_A);
  const forwardAuth = await (await send(t, key, "POST", "/v1/tls-forward-auths", { url: "https://auth.example.com/check", headers: { authorization: SECRET } })).json<ForwardAuthView>();
  const created = await send(t, key, "POST", "/v1/tls-rules", ingress("app.example.com", vm.vmId, { forwardAuthId: forwardAuth.id }));
  expect(created.status).toBe(201);
  const rule = await created.json<RuleView>();
  const verification = (await (await send(t, key, "GET", "/v1/domain-verifications?state=verified")).json<{ items: Verification[] }>()).items[0];
  if (verification === undefined) throw new Error("fixture: no verified verification");
  return { key, domain, pending, vm, forwardAuth, rule, verification };
};
type Fixtures = Awaited<ReturnType<typeof fixtures>>;

type Endpoint = (typeof DOMAIN_ENDPOINTS)[number];
const pathOf = (endpoint: Endpoint, f: Fixtures): string => endpoint.template
  .replace("{domainId}", f.domain.id)
  .replace("{verificationId}", endpoint.name === "deleteDomainVerification" ? f.pending.id : f.verification.id)
  .replace("{ruleId}", f.rule.id)
  .replace("{forwardAuthId}", f.forwardAuth.id);
const bodyOf = (endpoint: Endpoint, f: Fixtures): unknown => {
  switch (endpoint.name) {
    case "createDomainVerification":
      return { domain: "another.test" };
    case "createTlsRule":
    case "updateTlsRule":
      return ingress("app.example.com", f.vm.vmId);
    case "createTlsForwardAuth":
    case "updateTlsForwardAuth":
      return { url: "https://auth.example.com/other" };
    default:
      return undefined;
  }
};
const call = (t: Harness, endpoint: Endpoint, f: Fixtures, headers: Record<string, string>) => {
  const body = bodyOf(endpoint, f);
  return t.request(pathOf(endpoint, f), headers, body === undefined ? { method: endpoint.method } : { method: endpoint.method, body });
};

describe.each(DOMAIN_ENDPOINTS)("$name", (endpoint) => {
  it(`refuses a key without ${endpoint.scope} with 403 and calls nothing upstream`, async () => {
    const t = await harness();
    const f = await fixtures(t);
    const before = t.upstreamRequests.length;
    const key = await t.addKey(TENANT_A, allScopesExcept(endpoint.scope));
    const response = await call(t, endpoint, f, bearer(key));
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ _tag: "Forbidden", missingScope: endpoint.scope });
    expect(t.upstreamRequests).toHaveLength(before);
  });

  if (endpoint.target !== "tenant") {
    it("answers 404 to another tenant's key with every scope, and calls nothing upstream", async () => {
      const t = await harness();
      const f = await fixtures(t);
      const before = t.upstreamRequests.length;
      const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
      const response = await call(t, endpoint, f, bearer(keyB));
      expect(response.status).toBe(404);
      expect(t.upstreamRequests).toHaveLength(before);
    });

    it("answers 404 to a signed-in member of another team", async () => {
      const t = await harness();
      const f = await fixtures(t);
      t.addMember(TENANT_B, "user_bob");
      const token = await t.sessionToken("user_bob");
      const response = await call(t, endpoint, f, { ...bearer(token), "x-cmux-team-id": TENANT_B });
      expect(response.status).toBe(404);
    });

    it("answers 404 to a key whose allowlist omits the resource", async () => {
      const t = await harness();
      const f = await fixtures(t);
      const key = await t.addKey(TENANT_A, ALL_SCOPES, { allowlist: [f.vm.vmId] });
      expect((await call(t, endpoint, f, bearer(key))).status).toBe(404);
    });

    it("answers 404 to a service key of the same team", async () => {
      const t = await harness();
      const f = await fixtures(t);
      const key = await t.addServiceKey({ scopes: ["domain:read", "domain:write", "vm:network", "vm:read"] });
      expect((await call(t, endpoint, f, { ...bearer(key), "x-cmux-team-id": TENANT_A })).status).toBe(404);
    });
  }
});

describe("lists", () => {
  it("never show another tenant's resources, and show a confined key nothing", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const service = await t.addServiceKey({ scopes: ["domain:read"] });
    for (const path of ["/v1/domains", "/v1/domain-verifications", "/v1/tls-rules", "/v1/tls-forward-auths", "/v1/certificates"]) {
      for (const headers of [bearer(keyB), { ...bearer(service), "x-cmux-team-id": TENANT_A }]) {
        const response = await t.request(path, headers);
        expect(response.status).toBe(200);
        expect((await response.json<{ items: unknown[] }>()).items).toEqual([]);
      }
      const own = await send(t, f.key, "GET", path);
      expect(own.status).toBe(200);
    }
    expect((await (await send(t, f.key, "GET", "/v1/domains")).json<{ items: DomainView[] }>()).items.map((item) => item.id)).toEqual([f.domain.id]);
    expect((await (await send(t, f.key, "GET", "/v1/tls-rules")).json<{ items: RuleView[] }>()).items.map((item) => item.id)).toEqual([f.rule.id]);
  });

  it("refuse creates from service, agent-confined and allowlisted keys before any provider request", async () => {
    const t = await harness();
    const service = await t.addServiceKey({ scopes: ["domain:write", "vm:network"] });
    const allowlisted = await t.addKey(TENANT_A, ALL_SCOPES, { allowlist: ["vm_00000000000000000000000000"] });
    for (const headers of [{ ...bearer(service), "x-cmux-team-id": TENANT_A }, bearer(allowlisted)]) {
      expect((await t.request("/v1/domain-verifications", headers, { method: "POST", body: { domain: "x.test" } })).status).toBe(403);
      expect((await t.request("/v1/tls-forward-auths", headers, { method: "POST", body: { url: "https://auth.x.test/" } })).status).toBe(403);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });
});

describe("domain verification", () => {
  it("verifies only after this challenge's TXT record is published", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ["domain:read", "domain:write"]);
    const created = await send(t, key, "POST", "/v1/domain-verifications", { domain: "Example.COM" });
    expect(created.status).toBe(201);
    const verification = await created.json<Verification>();
    expect(verification).toMatchObject({ domain: "example.com", state: "pending" });
    expect(JSON.stringify(verification)).not.toMatch(/dv-/u);
    expect((await send(t, key, "POST", `/v1/domain-verifications/${verification.id}/verify`)).status).toBe(400);
    t.domains.publishTxt(verification.record.name, verification.record.value);
    const verified = await send(t, key, "POST", `/v1/domain-verifications/${verification.id}/verify`);
    expect(verified.status).toBe(200);
    const domain = await verified.json<DomainView & { dns: unknown }>();
    expect(domain).toMatchObject({ domain: "example.com", dns: { routing: { type: "CNAME", value: "edge.cmux.test" } } });
    // Retrying after success returns the same domain; a verified challenge cannot be withdrawn.
    expect((await (await send(t, key, "POST", `/v1/domain-verifications/${verification.id}/verify`)).json<DomainView>()).id).toBe(domain.id);
    expect((await send(t, key, "DELETE", `/v1/domain-verifications/${verification.id}`)).status).toBe(409);
  });

  it("lets only one team hold a domain, and lets a lapsed reservation be taken over", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const pending = await (await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "shared.test" })).json<Verification>();
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "shared.test" })).status).toBe(409);
    // Eight days later the unverified reservation lapses.
    const row = t.domains.rows.domains.find((candidate) => candidate.domain === "shared.test");
    if (row === undefined) throw new Error("no reservation");
    t.domains.rows.domains[t.domains.rows.domains.indexOf(row)] = { ...row, createdAt: new Date(Date.now() - 8 * 24 * 3600 * 1000) };
    const staleChallenge = t.domains.rows.verifications.find((candidate) => candidate.id === pending.id)?.upstreamId;
    if (staleChallenge === undefined) throw new Error("no challenge");
    const taken = await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "shared.test" });
    expect(taken.status).toBe(201);
    // A's old challenge is withdrawn at the provider and forgotten here: the reservation is no longer A's.
    expect(t.domains.challenges.has(staleChallenge)).toBe(false);
    t.domains.publishTxt(pending.record.name, pending.record.value);
    expect((await send(t, keyA, "POST", `/v1/domain-verifications/${pending.id}/verify`)).status).toBe(404);
    const takenView = await taken.json<Verification>();
    t.domains.publishTxt(takenView.record.name, takenView.record.value);
    expect((await send(t, keyB, "POST", `/v1/domain-verifications/${takenView.id}/verify`)).status).toBe(200);
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "shared.test" })).status).toBe(409);
  });

  it("withdraws a pending challenge but keeps the reservation until it lapses", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const pending = await (await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "free.test" })).json<Verification>();
    expect((await send(t, keyA, "DELETE", `/v1/domain-verifications/${pending.id}`)).status).toBe(204);
    expect(t.domains.rows.verifications.find((row) => row.id === pending.id)).toBeUndefined();
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "free.test" })).status).toBe(409);
  });

  it("refuses names under the managed zone and malformed names", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    for (const domain of [ZONE, `x.${ZONE}`, "cmux.test", "*.example.com", "10.0.0.1", "localhost", "a..b"]) {
      expect((await send(t, key, "POST", "/v1/domain-verifications", { domain })).status, domain).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });

  it("releases a domain only once no rule of the team routes under it", async () => {
    const t = await harness();
    const f = await fixtures(t);
    expect((await send(t, f.key, "DELETE", `/v1/domains/${f.domain.id}`)).status).toBe(409);
    expect((await send(t, f.key, "DELETE", `/v1/tls-rules/${f.rule.id}`)).status).toBe(204);
    expect((await send(t, f.key, "DELETE", `/v1/domains/${f.domain.id}`)).status).toBe(204);
    expect((await send(t, f.key, "GET", `/v1/domains/${f.domain.id}`)).status).toBe(404);
  });
});

describe("certificates", () => {
  it("lists only certificates under the team's verified domains, the most specific owner deciding", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    await verifyOwn(t, keyA, "example.com");
    await verifyOwn(t, keyB, "sub.example.com");
    for (const domain of ["example.com", "www.example.com", "sub.example.com", "x.sub.example.com", "other.test"]) {
      t.domains.certificates.push({ domain, wildcard: false, active: true, notAfter: "2027-01-01T00:00:00Z", generation: 1 });
    }
    const listed = async (key: string) => (await (await send(t, key, "GET", "/v1/certificates")).json<{ items: Array<{ domain: string }> }>()).items.map((item) => item.domain);
    expect(await listed(keyA)).toEqual(["example.com", "www.example.com"]);
    expect(await listed(keyB)).toEqual(["sub.example.com", "x.sub.example.com"]);
  });

  it("requests a wildcard only for the team's own verified domain once DNS is delegated", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const domain = await verifyOwn(t, keyA, "example.com");
    expect((await send(t, keyA, "POST", `/v1/domains/${domain.id}/wildcard-certificate`)).status).toBe(400);
    t.domains.delegate("example.com");
    const issued = await send(t, keyA, "POST", `/v1/domains/${domain.id}/wildcard-certificate`);
    expect(issued.status).toBe(200);
    expect(await issued.json()).toMatchObject({ domain: "example.com", wildcard: true });
    expect((await send(t, keyB, "POST", `/v1/domains/${domain.id}/wildcard-certificate`)).status).toBe(404);
  });
});

describe("TLS rules", () => {
  it("routes a verified name to the team's VM, sending provider ids upstream and returning only cmux ids", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const call = t.upstream.callsTo("POST", /^\/v5\/tls$/u)[0];
    const auth = t.upstream.callsTo("POST", /^\/v5\/tls\/forward-auth$/u)[0];
    expect(call?.json).toMatchObject({ action: "allow", domain: "app.example.com", protocol: "http", source: { public: true }, destination: { vmId: f.vm.upstreamId, port: 3000 } });
    expect(JSON.stringify(call?.json)).toContain(`"forwardAuth":{"id":"fa-`);
    expect(auth?.json).toMatchObject({ url: "https://auth.example.com/check", headers: { authorization: SECRET } });
    expect(f.rule).toMatchObject({ domain: "app.example.com", direction: "ingress", destination: { vmId: f.vm.vmId, port: 3000 }, forwardAuthId: f.forwardAuth.id });
    const text = JSON.stringify([f.rule, f.forwardAuth, await (await send(t, f.key, "GET", `/v1/tls-forward-auths/${f.forwardAuth.id}`)).json()]);
    expect(text).not.toContain(SECRET);
    expect(text).not.toContain(f.vm.upstreamId);
    expect(text).not.toMatch(/"(fa|tls)-/u);
    expect(f.forwardAuth.headerNames).toEqual(["authorization"]);
    expect(JSON.stringify(t.audit)).not.toContain(SECRET);
    expect(t.audit).toContainEqual(expect.objectContaining({ tenantId: TENANT_A, action: "tls_rule.create", cmuxId: f.rule.id, outcome: "ok" }));
  });

  it("refuses another tenant's VM or forward-auth check as 404 without a provider request", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    await verifyOwn(t, keyB, "bravo.test");
    const before = t.upstreamRequests.length;
    expect((await send(t, keyB, "POST", "/v1/tls-rules", ingress("bravo.test", f.vm.vmId))).status).toBe(404);
    const vmB = t.addVm(TENANT_B);
    expect((await send(t, keyB, "POST", "/v1/tls-rules", ingress("bravo.test", vmB.vmId, { forwardAuthId: f.forwardAuth.id }))).status).toBe(404);
    expect(t.upstreamRequests).toHaveLength(before);
  });

  it("refuses names the team does not own, whoever owns them", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    await verifyOwn(t, keyA, "example.com");
    await verifyOwn(t, keyB, "sub.example.com");
    const vmA = t.addVm(TENANT_A);
    const before = t.upstreamRequests.length;
    for (const domain of ["unverified.test", "sub.example.com", "x.sub.example.com", "deep.x.example.com", "*.unverified.test", "*.example.com", "*", `*.${ZONE}`]) {
      const response = await send(t, keyA, "POST", "/v1/tls-rules", ingress(domain, vmA.vmId));
      expect(response.status, domain).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(before);
    expect((await send(t, keyA, "POST", "/v1/tls-rules", ingress("www.example.com", vmA.vmId))).status).toBe(201);
    expect((await send(t, keyA, "POST", "/v1/tls-rules", ingress("example.com", vmA.vmId))).status).toBe(201);
  });

  it("allows a wildcard over a verified domain when no other team owns a child of it", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    await verifyOwn(t, keyA, "wild.test");
    const vmA = t.addVm(TENANT_A);
    expect((await send(t, keyA, "POST", "/v1/tls-rules", ingress("*.wild.test", vmA.vmId))).status).toBe(201);
  });

  it("routes only the team's own managed hostnames", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const suffixOf = async (key: string) => (await (await send(t, key, "GET", "/v1/domains")).json<{ managedSuffix: string }>()).managedSuffix;
    const suffixA = await suffixOf(keyA);
    const suffixB = await suffixOf(keyB);
    expect(suffixA).toMatch(new RegExp(`^--[0-9a-f]{10}\\.${ZONE.replaceAll(".", "\\.")}$`, "u"));
    expect(suffixA).not.toBe(suffixB);
    const vmA = t.addVm(TENANT_A);
    expect((await send(t, keyA, "POST", "/v1/tls-rules", ingress(`app${suffixA}`, vmA.vmId))).status).toBe(201);
    for (const domain of [`app${suffixB}`, `app.${ZONE}`, ZONE, `a.b${suffixA}`]) {
      expect((await send(t, keyA, "POST", "/v1/tls-rules", ingress(domain, vmA.vmId))).status, domain).toBe(400);
    }
  });

  it("lets egress reach only an approved HTTPS origin, with write-only headers", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    const vm = t.addVm(TENANT_A);
    const egress = (destination: unknown, domain = "api.example.test") => ({ domain, source: { vmId: vm.vmId }, destination, headers: { authorization: SECRET } });
    const created = await send(t, key, "POST", "/v1/tls-rules", egress({ public: true }));
    expect(created.status).toBe(201);
    const rule = await created.json<RuleView>();
    expect(rule.headerNames).toEqual(["authorization"]);
    expect(JSON.stringify(rule)).not.toContain(SECRET);
    expect(t.upstream.callsTo("POST", /^\/v5\/tls$/u).at(-1)?.json).toMatchObject({ source: { vmId: vm.upstreamId }, destination: { public: true }, transform: [{ headers: { authorization: SECRET } }] });
    expect((await send(t, key, "POST", "/v1/tls-rules", egress({ host: "api.example.test", port: 443 }, "alias.internal"))).status).toBe(201);
    for (const destination of [{ public: true, port: 443 }, { host: "evil.test", port: 443 }, { host: "api.example.test", port: 8443 }, { vmId: vm.vmId, port: 80 }]) {
      expect((await send(t, key, "POST", "/v1/tls-rules", egress(destination, "alias2.internal"))).status, JSON.stringify(destination)).toBe(400);
    }
    expect((await send(t, key, "POST", "/v1/tls-rules", egress({ public: true }, "unapproved.test"))).status).toBe(400);
  });

  it("refuses private networks, socks5 and unknown fields", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    const vm = t.addVm(TENANT_A);
    await verifyOwn(t, key, "example.com");
    const before = t.upstreamRequests.length;
    for (const body of [
      { domain: "a.example.com", source: { vpcId: "vpc-1" }, destination: { vmId: vm.vmId, port: 80 } },
      { ...ingress("a.example.com", vm.vmId), protocol: "socks5" },
      { ...ingress("a.example.com", vm.vmId), transform: [{ postgres: { username: "u", password: "p" } }] },
      { domain: "a.example.com", source: { public: true, vmId: vm.vmId }, destination: { vmId: vm.vmId, port: 80 } },
    ]) {
      expect((await send(t, key, "POST", "/v1/tls-rules", body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(before);
  });

  it("needs vm:network as well as domain:write", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const key = await t.addKey(TENANT_A, allScopesExcept("vm:network"));
    const response = await send(t, key, "POST", "/v1/tls-rules", ingress("www.example.com", f.vm.vmId));
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ missingScope: "vm:network" });
  });

  it("replaces a rule in place and forgets it once the provider deleted it with its VM", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const updated = await send(t, f.key, "PUT", `/v1/tls-rules/${f.rule.id}`, ingress("www.example.com", f.vm.vmId));
    expect(updated.status).toBe(200);
    expect(await updated.json()).toMatchObject({ id: f.rule.id, domain: "www.example.com", forwardAuthId: null });
    t.upstream.tlsRules.clear();
    expect((await send(t, f.key, "GET", `/v1/tls-rules/${f.rule.id}`)).status).toBe(404);
    expect(t.domains.rows.rules).toHaveLength(0);
  });

  it("hides a rule whose VM is gone or out of the key's reach", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const other = t.addVm(TENANT_A);
    const limited = await t.addKey(TENANT_A, ALL_SCOPES, { allowlist: [other.vmId, f.rule.id] });
    expect((await (await send(t, limited, "GET", "/v1/tls-rules")).json<{ items: unknown[] }>()).items).toEqual([]);
    expect((await (await send(t, f.key, "GET", `/v1/tls-rules?vmId=${other.vmId}`)).json<{ items: unknown[] }>()).items).toEqual([]);
    expect((await (await send(t, f.key, "GET", `/v1/tls-rules?vmId=${f.vm.vmId}`)).json<{ items: unknown[] }>()).items).toHaveLength(1);
  });
});

describe("forward-auth checks", () => {
  it("rotates headers in place and refuses deletion while a rule uses the check", async () => {
    const t = await harness();
    const f = await fixtures(t);
    const rotated = await send(t, f.key, "PUT", `/v1/tls-forward-auths/${f.forwardAuth.id}`, { url: "https://auth.example.com/check", headers: { "x-token": "rotated-secret" } });
    expect(rotated.status).toBe(200);
    const view = await rotated.json<ForwardAuthView>();
    expect(view.headerNames).toEqual(["x-token"]);
    expect(JSON.stringify(view)).not.toContain("rotated-secret");
    expect((await send(t, f.key, "DELETE", `/v1/tls-forward-auths/${f.forwardAuth.id}`)).status).toBe(409);
    expect((await send(t, f.key, "DELETE", `/v1/tls-rules/${f.rule.id}`)).status).toBe(204);
    expect((await send(t, f.key, "DELETE", `/v1/tls-forward-auths/${f.forwardAuth.id}`)).status).toBe(204);
  });

  it("accepts only an HTTPS URL on a DNS name", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    for (const url of ["http://auth.example.com/", "https://user:pw@auth.example.com/", "https://127.0.0.1/", "https://localhost/", "not a url"]) {
      expect((await send(t, key, "POST", "/v1/tls-forward-auths", { url })).status, url).toBe(400);
    }
    expect(t.upstreamRequests).toHaveLength(0);
  });
});

describe("review fixes (https://github.com/manaflow-ai/cmux/pull/25367)", () => {
  const lapse = (t: Harness, domain: string, days: number) => {
    const row = t.domains.rows.domains.find((candidate) => candidate.domain === domain);
    if (row === undefined) throw new Error("no reservation");
    t.domains.rows.domains[t.domains.rows.domains.indexOf(row)] = { ...row, createdAt: new Date(Date.now() - days * 24 * 3600 * 1000) };
  };

  it("deleting a VM deletes its TLS rules at the provider and here, so the domain and forward-auth check can be released", async () => {
    const t = await harness();
    const f = await fixtures(t);
    expect((await send(t, f.key, "DELETE", `/v1/vms/${f.vm.vmId}`)).status).toBe(204);
    expect(t.domains.rows.rules).toHaveLength(0);
    expect(t.upstream.tlsRules.size).toBe(0);
    expect((await send(t, f.key, "DELETE", `/v1/domains/${f.domain.id}`)).status).toBe(204);
    expect((await send(t, f.key, "DELETE", `/v1/tls-forward-auths/${f.forwardAuth.id}`)).status).toBe(204);
  });

  it("an already-orphaned rule never blocks a release, holds no budget, and can itself be deleted", async () => {
    const t = await harness();
    const f = await fixtures(t);
    // The VM was tombstoned by a path that ran no cleanup (or by an older release): its rule is an orphan.
    t.markDeleted(f.vm.vmId);
    const tenant = t.domains.rows.rules[0]?.tenantId;
    if (tenant === undefined) throw new Error("no rule");
    expect(await Effect.runPromise(t.domains.rows.store.countTlsRules(tenant))).toBe(0);
    expect((await (await send(t, f.key, "GET", "/v1/tls-rules")).json<{ items: unknown[] }>()).items).toEqual([]);
    expect((await send(t, f.key, "DELETE", `/v1/tls-rules/${f.rule.id}`)).status).toBe(204);
    expect(t.upstream.tlsRules.size).toBe(0);
    expect((await send(t, f.key, "DELETE", `/v1/domains/${f.domain.id}`)).status).toBe(204);
    expect((await send(t, f.key, "DELETE", `/v1/tls-forward-auths/${f.forwardAuth.id}`)).status).toBe(204);
  });

  it("a release cleans orphaned rules at the provider so the forward-auth check is no longer in use there", async () => {
    const t = await harness();
    const f = await fixtures(t);
    t.markDeleted(f.vm.vmId);
    expect((await send(t, f.key, "DELETE", `/v1/domains/${f.domain.id}`)).status).toBe(204);
    expect(t.upstream.tlsRules.size).toBe(0);
    expect(t.domains.rows.rules).toHaveLength(0);
    expect((await send(t, f.key, "DELETE", `/v1/tls-forward-auths/${f.forwardAuth.id}`)).status).toBe(204);
  });

  it("a re-claim never extends an unverified reservation: after the first claim's lapse another team takes it", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "held.test" })).status).toBe(201);
    lapse(t, "held.test", 8);
    // A asks again: that does not renew the reservation (A is in its re-claim cooldown).
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "held.test" })).status).toBe(409);
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "held.test" })).status).toBe(201);
    expect(t.domains.rows.verifications.filter((row) => row.domain === "held.test").map((row) => row.tenantId)).toEqual([TENANT_B]);
  });

  it("cycling withdraw and create never extends an unverified hold past the first claim's lapse", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const first = await (await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "cycle.test" })).json<Verification>();
    const reservation = t.domains.rows.domains.find((row) => row.domain === "cycle.test");
    // Six days later A withdraws its only challenge and starts again.
    lapse(t, "cycle.test", 6);
    expect((await send(t, keyA, "DELETE", `/v1/domain-verifications/${first.id}`)).status).toBe(204);
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "cycle.test" })).status).toBe(409);
    const second = await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "cycle.test" });
    expect(second.status).toBe(201);
    const held = t.domains.rows.domains.find((row) => row.domain === "cycle.test");
    expect(held?.id).toBe(reservation?.id);
    expect(Date.now() - (held?.createdAt.getTime() ?? 0)).toBeGreaterThanOrEqual(6 * 24 * 3600 * 1000 - 60_000);
    // Two more days: the first claim lapsed. A withdraws again and is refused during its cooldown; B takes it.
    lapse(t, "cycle.test", 8);
    expect((await send(t, keyA, "DELETE", `/v1/domain-verifications/${(await second.json<Verification>()).id}`)).status).toBe(204);
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "cycle.test" })).status).toBe(409);
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "cycle.test" })).status).toBe(201);
    expect(t.domains.rows.domains.find((row) => row.domain === "cycle.test")?.tenantId).toBe(TENANT_B);
  });

  it("after a lapse another team claims at once while the previous holder gets 409 for the cooldown, then may claim afresh", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "cool.test" })).status).toBe(201);
    lapse(t, "cool.test", 13);
    const refused = await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "cool.test" });
    expect(refused.status).toBe(409);
    expect(JSON.stringify(await refused.json())).toMatch(/lapsed/u);
    // Past the cooldown A gets a fresh seven-day reservation, which keeps B out again.
    lapse(t, "cool.test", 15);
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "cool.test" })).status).toBe(201);
    expect(Date.now() - (t.domains.rows.domains.find((row) => row.domain === "cool.test")?.createdAt.getTime() ?? 0)).toBeLessThan(60_000);
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "cool.test" })).status).toBe(409);
  });

  it("a release withdraws the domain's pending challenges at the provider", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    const first = await (await send(t, key, "POST", "/v1/domain-verifications", { domain: "two.test" })).json<Verification>();
    const second = await (await send(t, key, "POST", "/v1/domain-verifications", { domain: "two.test" })).json<Verification>();
    const secondChallenge = t.domains.rows.verifications.find((row) => row.id === second.id)?.upstreamId;
    if (secondChallenge === undefined) throw new Error("no challenge");
    t.domains.publishTxt(first.record.name, first.record.value);
    const domain = await (await send(t, key, "POST", `/v1/domain-verifications/${first.id}/verify`)).json<DomainView>();
    expect((await send(t, key, "DELETE", `/v1/domains/${domain.id}`)).status).toBe(204);
    expect(t.domains.challenges.has(secondChallenge)).toBe(false);
  });

  it("accepts a provider answer naming another challenge of the same team for the domain, and no other", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const first = await (await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "sib.test" })).json<Verification>();
    const second = await (await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "sib.test" })).json<Verification>();
    const upstreamOf = (id: string) => t.domains.rows.verifications.find((row) => row.id === id)?.upstreamId ?? "";
    t.domains.publishTxt(first.record.name, first.record.value);
    t.domains.publishTxt(second.record.name, second.record.value);
    t.domains.nameVerifier(upstreamOf(second.id), upstreamOf(first.id));
    expect((await send(t, keyA, "POST", `/v1/domain-verifications/${second.id}/verify`)).status).toBe(200);
    // Another team's challenge never counts.
    const other = await (await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "other.test" })).json<Verification>();
    t.domains.publishTxt(other.record.name, other.record.value);
    t.domains.nameVerifier(upstreamOf(other.id), upstreamOf(first.id));
    expect((await send(t, keyB, "POST", `/v1/domain-verifications/${other.id}/verify`)).status).toBe(503);
  });

  it("releases the reservation and the challenge when recording a new verification fails", async () => {
    const t = await harness();
    const keyA = await t.addKey(TENANT_A, ALL_SCOPES);
    const keyB = await t.addKey(TENANT_B, ALL_SCOPES);
    const store = t.domains.rows.store;
    const insert = store.insertVerification;
    Object.assign(store, { insertVerification: () => Effect.fail(new StoreError({ operation: "verifications.insert", cause: "injected" })) });
    expect((await send(t, keyA, "POST", "/v1/domain-verifications", { domain: "fail.test" })).status).toBe(503);
    Object.assign(store, { insertVerification: insert });
    expect(t.domains.challenges.size).toBe(0);
    expect((await send(t, keyB, "POST", "/v1/domain-verifications", { domain: "fail.test" })).status).toBe(201);
  });

  it("withdraws and forgets a challenge whose reservation is gone when it verifies", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    const pending = await (await send(t, key, "POST", "/v1/domain-verifications", { domain: "gone.test" })).json<Verification>();
    t.domains.rows.domains.splice(t.domains.rows.domains.findIndex((row) => row.domain === "gone.test"), 1);
    t.domains.publishTxt(pending.record.name, pending.record.value);
    expect((await send(t, key, "POST", `/v1/domain-verifications/${pending.id}/verify`)).status).toBe(409);
    expect(t.upstream.callsTo("DELETE", /^\/v5\/verifications\//u)).toHaveLength(1);
    expect(t.domains.rows.verifications.find((row) => row.id === pending.id)).toBeUndefined();
  });

  it("does not keep a rule whose domain was released while the provider created it", async () => {
    const t = await harness();
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    await verifyOwn(t, key, "race.test");
    const vm = t.addVm(TENANT_A);
    const upstream = t.domains.upstream;
    t.domains.upstream = async (request: Request) => {
      const response = await upstream(request);
      if (request.method === "POST" && new URL(request.url).pathname === "/v5/tls") {
        // A concurrent DELETE /v1/domains/{id} lands between the policy check and the insert.
        t.domains.rows.domains.splice(t.domains.rows.domains.findIndex((row) => row.domain === "race.test"), 1);
      }
      return response;
    };
    const response = await send(t, key, "POST", "/v1/tls-rules", ingress("app.race.test", vm.vmId));
    t.domains.upstream = upstream;
    expect(response.status).toBe(400);
    expect(t.domains.rows.rules).toHaveLength(0);
    expect(t.upstream.tlsRules.size).toBe(0);
  });

  it("enforces the forward-auth and pending-verification budgets at the insert, not only at the first count", async () => {
    const t = await harness({ ratePerMinute: { write: 1000 } });
    const key = await t.addKey(TENANT_A, ALL_SCOPES);
    for (let index = 0; index < DOMAIN_LIMITS.forwardAuths; index += 1) {
      expect((await send(t, key, "POST", "/v1/tls-forward-auths", { url: `https://auth.example.com/${index}` })).status).toBe(201);
    }
    for (let index = 0; index < DOMAIN_LIMITS.pendingVerifications; index += 1) {
      expect((await send(t, key, "POST", "/v1/domain-verifications", { domain: `d${index}.test` })).status).toBe(201);
    }
    // A concurrent request read the counts before the last creates landed.
    const store = t.domains.rows.store;
    const counts = { forwardAuths: store.countForwardAuths, pending: store.countPendingVerifications };
    Object.assign(store, { countForwardAuths: () => Effect.succeed(0), countPendingVerifications: () => Effect.succeed(0) });
    const fa = await send(t, key, "POST", "/v1/tls-forward-auths", { url: "https://auth.example.com/over" });
    const dv = await send(t, key, "POST", "/v1/domain-verifications", { domain: "over.test" });
    Object.assign(store, { countForwardAuths: counts.forwardAuths, countPendingVerifications: counts.pending });
    expect(fa.status).toBe(429);
    expect(dv.status).toBe(429);
    expect(t.domains.forwardAuths.size).toBe(DOMAIN_LIMITS.forwardAuths);
    expect(t.domains.rows.forwardAuths).toHaveLength(DOMAIN_LIMITS.forwardAuths);
    expect(t.domains.challenges.size).toBe(DOMAIN_LIMITS.pendingVerifications);
    expect(t.domains.rows.domains.some((row) => row.domain === "over.test")).toBe(false);
  });
});
