/**
 * The domain store (migration 0018, cx-b4h.6) on an in-process Postgres
 * (PGlite): one reservation per domain across tenants, lapsed takeovers, the
 * cross-tenant ownership questions, and tenant-keyed rule and forward-auth rows.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import domainsTls from "../../migrations/0018_cmux_vm_domains_tls.sql?raw";
import { DomainStore, sqlDomainStoreLayer, type DomainStoreService, type TlsRuleRow } from "../../src/db/domains.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { newDomainId, newDomainVerificationId, newForwardAuthId, newTlsRuleId } from "../../src/lib/domain-ids.ts";
import { newVmId, TenantId, UpstreamId } from "../../src/lib/ids.ts";

const A = TenantId.make("team_alpha");
const B = TenantId.make("team_bravo");
const DAY = 24 * 60 * 60 * 1000;

let layer: Layer.Layer<DomainStore>;
const run = <X, E>(effect: Effect.Effect<X, E, DomainStore>) => Effect.runPromise(Effect.provide(effect, layer));
const store = <X, E>(f: (s: DomainStoreService) => Effect.Effect<X, E>) => run(Effect.flatMap(DomainStore, f));

beforeEach(async () => {
  const pg = new PGlite();
  await pg.exec(ownership);
  await pg.exec(domainsTls);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  layer = sqlDomainStoreLayer.pipe(Layer.provide(sql));
});

const claim = (tenant: TenantId, domain: string, at: Date) =>
  store((s) => s.claimDomain(tenant, domain, newDomainId(), "user:test", at, new Date(at.getTime() - 7 * DAY)));

describe("domain reservations", () => {
  it("hold one domain for one tenant until verified, refreshable by the holder", async () => {
    const now = new Date();
    const first = await claim(A, "example.com", now);
    expect(first.kind).toBe("claimed");
    expect((await claim(B, "example.com", now)).kind).toBe("taken");
    const again = await claim(A, "example.com", new Date(now.getTime() + 1000));
    expect(again.kind === "claimed" && first.kind === "claimed" && again.row.id === first.row.id).toBe(true);
    expect(await store((s) => s.markDomainVerified(B, "example.com", now))).toBeNull();
    expect((await store((s) => s.markDomainVerified(A, "example.com", now)))?.verifiedAt).not.toBeNull();
    expect((await claim(A, "example.com", now)).kind).toBe("verified");
    expect((await claim(B, "example.com", new Date(now.getTime() + 30 * DAY))).kind).toBe("taken");
  });

  it("let another tenant take over a lapsed pending reservation, with a new id", async () => {
    const old = new Date(Date.now() - 8 * DAY);
    const first = await claim(A, "lapsed.test", old);
    const taken = await claim(B, "lapsed.test", new Date());
    expect(taken.kind).toBe("claimed");
    if (first.kind !== "claimed" || taken.kind !== "claimed") throw new Error("unexpected");
    expect(taken.row.id).not.toBe(first.row.id);
    expect(taken.row.tenantId).toBe(B);
    expect(await store((s) => s.markDomainVerified(A, "lapsed.test", new Date()))).toBeNull();
  });

  it("release a pending reservation only when no verification of the tenant remains", async () => {
    const now = new Date();
    await claim(A, "release.test", now);
    await store((s) => s.insertVerification({
      id: newDomainVerificationId(), tenantId: A, domain: "release.test", upstreamId: UpstreamId.make("dv-1"),
      recordName: "_challenge.release.test", code: "code", createdBy: "user:test", createdAt: now, verifiedAt: null,
    }));
    await store((s) => s.releasePendingClaim(A, "release.test"));
    expect((await claim(B, "release.test", now)).kind).toBe("taken");
    const [verification] = await store((s) => s.listVerifications(A, "pending"));
    if (verification === undefined) throw new Error("no verification");
    expect(await store((s) => s.deletePendingVerification(B, verification.id))).toBe(false);
    expect(await store((s) => s.deletePendingVerification(A, verification.id))).toBe(true);
    await store((s) => s.releasePendingClaim(A, "release.test"));
    expect((await claim(B, "release.test", now)).kind).toBe("claimed");
  });

  it("answer who verified a name and what lies below it", async () => {
    const now = new Date();
    for (const [tenant, domain] of [[A, "example.com"], [B, "sub.example.com"], [B, "pending.example.com"]] as const) await claim(tenant, domain, now);
    await store((s) => s.markDomainVerified(A, "example.com", now));
    await store((s) => s.markDomainVerified(B, "sub.example.com", now));
    expect(await store((s) => s.verifiedOwners(["x.sub.example.com", "sub.example.com", "example.com"]))).toEqual(
      expect.arrayContaining([{ domain: "sub.example.com", tenantId: B }, { domain: "example.com", tenantId: A }]));
    expect(await store((s) => s.verifiedBelow("example.com"))).toEqual([{ domain: "sub.example.com", tenantId: B }]);
    expect(await store((s) => s.verifiedBelow("ample.com"))).toEqual([]);
    expect((await store((s) => s.listDomains(A))).map((row) => row.domain)).toEqual(["example.com"]);
    expect(await store((s) => s.listDomains(B))).toHaveLength(1);
  });
});

describe("TLS rules and forward-auth rows", () => {
  it("are keyed by tenant and count rules under a domain", async () => {
    const now = new Date();
    const fwa = newForwardAuthId();
    await store((s) => s.insertForwardAuth({
      id: fwa, tenantId: A, upstreamId: UpstreamId.make("fa-1"), url: "https://auth.example.com/", timeoutMs: 1500,
      headerNames: ["authorization"], authResponseHeaders: [], protectedCookies: ["session"], createdBy: "user:test", createdAt: now, updatedAt: now,
    }));
    const vmId = newVmId();
    const rule = (domain: string): TlsRuleRow => ({
      id: newTlsRuleId(), tenantId: A, upstreamId: UpstreamId.make(`tls-${domain}`), domain, vmIds: [vmId], forwardAuthId: fwa,
      spec: { domain, protocol: "http", direction: "ingress", source: { public: true }, destination: { vmId, port: 3000 }, forwardAuthId: fwa, match: null, headerNames: [], description: null },
      createdBy: "user:test", createdAt: now, updatedAt: now,
    });
    for (const domain of ["example.com", "www.example.com", "*.example.com", "notexample.com"]) await store((s) => s.insertTlsRule(rule(domain)));
    expect(await store((s) => s.countTlsRulesUnder(A, "example.com"))).toBe(3);
    expect(await store((s) => s.countTlsRulesUnder(B, "example.com"))).toBe(0);
    expect(await store((s) => s.countTlsRulesUsingForwardAuth(A, fwa))).toBe(4);
    const [listed] = await store((s) => s.listTlsRules(A));
    expect(listed?.spec.destination.vmId).toBe(vmId);
    expect(await store((s) => s.listTlsRules(B))).toEqual([]);
    expect(await store((s) => s.findForwardAuth(B, fwa))).toBeNull();
    const updated = await store((s) => s.updateForwardAuth(A, fwa, { url: "https://auth.example.com/v2", timeoutMs: 900, headerNames: [], authResponseHeaders: ["x-user"], protectedCookies: [] }, now));
    expect(updated).toMatchObject({ url: "https://auth.example.com/v2", timeoutMs: 900, authResponseHeaders: ["x-user"] });
    expect(await store((s) => s.updateForwardAuth(B, fwa, { url: "https://x.test/", timeoutMs: 900, headerNames: [], authResponseHeaders: [], protectedCookies: [] }, now))).toBeNull();
  });
});
