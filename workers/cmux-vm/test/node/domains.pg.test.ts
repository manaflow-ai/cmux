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
import { newDomainId, newDomainVerificationId, newForwardAuthId, newTlsRuleId, type ForwardAuthId } from "../../src/lib/domain-ids.ts";
import { newVmId, TenantId, UpstreamId, type VmId } from "../../src/lib/ids.ts";

const A = TenantId.make("team_alpha");
const B = TenantId.make("team_bravo");
const DAY = 24 * 60 * 60 * 1000;

let layer: Layer.Layer<DomainStore>;
let pg: PGlite;
const run = <X, E>(effect: Effect.Effect<X, E, DomainStore>) => Effect.runPromise(Effect.provide(effect, layer));
const store = <X, E>(f: (s: DomainStoreService) => Effect.Effect<X, E>) => run(Effect.flatMap(DomainStore, f));

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(ownership);
  await pg.exec(domainsTls);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  layer = sqlDomainStoreLayer.pipe(Layer.provide(sql));
});

/** Records a live VM of `tenant` in the ownership table (rules count only while their VMs live). */
const liveVm = async (tenant: TenantId, vmId: string) => {
  await pg.query("INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by) VALUES ($1, $2, 'vm', $3, 'user:test')", [vmId, tenant, `up-${vmId}`]);
};
const deleteVm = async (vmId: string) => {
  await pg.query("UPDATE cmux_vm.resources SET deleted_at = now() WHERE cmux_id = $1", [vmId]);
};
const ruleOn = (tenant: TenantId, domain: string, vmId: VmId, forwardAuthId: ForwardAuthId | null = null): TlsRuleRow => ({
  id: newTlsRuleId(), tenantId: tenant, upstreamId: UpstreamId.make(`tls-${crypto.randomUUID()}`), domain, vmIds: [vmId], forwardAuthId,
  spec: { domain, protocol: "http", direction: "ingress", source: { public: true }, destination: { vmId, port: 3000 }, forwardAuthId, match: null, headerNames: [], description: null },
  createdBy: "user:test", createdAt: new Date(), updatedAt: new Date(),
});
const verified = async (tenant: TenantId, domain: string) => {
  const now = new Date();
  await claim(tenant, domain, now);
  return store((s) => s.markDomainVerified(tenant, domain, now));
};

const claim = (tenant: TenantId, domain: string, at: Date) =>
  store((s) => s.claimDomain(tenant, domain, newDomainId(), "user:test", at, new Date(at.getTime() - 7 * DAY), new Date(at.getTime() - 14 * DAY)));

describe("domain reservations", () => {
  it("hold one domain for one tenant until verified; a re-claim by the holder changes nothing", async () => {
    const now = new Date();
    const first = await claim(A, "example.com", now);
    expect(first.kind).toBe("claimed");
    expect((await claim(B, "example.com", now)).kind).toBe("taken");
    const again = await claim(A, "example.com", new Date(now.getTime() + 1000));
    if (again.kind !== "claimed" || first.kind !== "claimed") throw new Error("unexpected");
    expect(again.row.id).toBe(first.row.id);
    expect(again.row.createdAt.getTime()).toBe(first.row.createdAt.getTime());
    expect(await store((s) => s.markDomainVerified(B, "example.com", now))).toBeNull();
    expect((await store((s) => s.markDomainVerified(A, "example.com", now)))?.verifiedAt).not.toBeNull();
    expect((await claim(A, "example.com", now)).kind).toBe("verified");
    expect((await claim(B, "example.com", new Date(now.getTime() + 30 * DAY))).kind).toBe("taken");
  });

  it("never extend a reservation on re-claim: the lapse counts from the first claim", async () => {
    const t0 = new Date(Date.now() - 8 * DAY);
    await claim(A, "held.test", t0);
    // The holder re-claims on day six; on day eight another tenant still takes it over.
    await claim(A, "held.test", new Date(t0.getTime() + 6 * DAY));
    const taken = await claim(B, "held.test", new Date(t0.getTime() + 8 * DAY));
    expect(taken.kind).toBe("claimed");
    if (taken.kind !== "claimed") throw new Error("unexpected");
    expect(taken.row.tenantId).toBe(B);
  });

  it("forget the previous holder's pending verifications on takeover and return them as displaced", async () => {
    const old = new Date(Date.now() - 8 * DAY);
    await claim(A, "displace.test", old);
    await store((s) => s.insertVerification({
      id: newDomainVerificationId(), tenantId: A, domain: "displace.test", upstreamId: UpstreamId.make("dv-old"),
      recordName: "_challenge.displace.test", code: "code", createdBy: "user:test", createdAt: old, verifiedAt: null,
    }, 20));
    const taken = await claim(B, "displace.test", new Date());
    if (taken.kind !== "claimed") throw new Error("unexpected");
    expect(taken.displaced.map((row) => row.upstreamId)).toEqual(["dv-old"]);
    expect(await store((s) => s.listVerifications(A, null))).toEqual([]);
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

  it("back out only the fresh reservation row a request created, and only while it has no verification", async () => {
    const now = new Date();
    const first = await claim(A, "release.test", now);
    if (first.kind !== "claimed") throw new Error("unexpected");
    await store((s) => s.insertVerification({
      id: newDomainVerificationId(), tenantId: A, domain: "release.test", upstreamId: UpstreamId.make("dv-1"),
      recordName: "_challenge.release.test", code: "code", createdBy: "user:test", createdAt: now, verifiedAt: null,
    }, 20));
    await store((s) => s.backOutFreshClaim(A, first.row.id));
    expect((await claim(B, "release.test", now)).kind).toBe("taken");
    const [verification] = await store((s) => s.listVerifications(A, "pending"));
    if (verification === undefined) throw new Error("no verification");
    expect(await store((s) => s.deletePendingVerification(B, verification.id))).toBe(false);
    expect(await store((s) => s.deletePendingVerification(A, verification.id))).toBe(true);
    // Another tenant cannot back out A's row; A's own back-out of its fresh row frees the domain.
    await store((s) => s.backOutFreshClaim(B, first.row.id));
    expect((await claim(B, "release.test", now)).kind).toBe("taken");
    await store((s) => s.backOutFreshClaim(A, first.row.id));
    expect((await claim(B, "release.test", now)).kind).toBe("claimed");
  });

  it("withdrawing every challenge and claiming again never extends the hold past the first claim's lapse", async () => {
    const t0 = new Date(Date.now() - 20 * DAY);
    const first = await claim(A, "cycle.test", t0);
    if (first.kind !== "claimed") throw new Error("unexpected");
    // Every six days A withdraws its challenge and asks again: the reservation keeps its first-claim time.
    for (const day of [6, 12]) {
      const verificationId = newDomainVerificationId();
      await store((s) => s.insertVerification({
        id: verificationId, tenantId: A, domain: "cycle.test", upstreamId: UpstreamId.make(`dv-${day}`),
        recordName: "_challenge.cycle.test", code: "code", createdBy: "user:test", createdAt: new Date(t0.getTime() + day * DAY), verifiedAt: null,
      }, 20));
      expect(await store((s) => s.deletePendingVerification(A, verificationId))).toBe(true);
      const again = await claim(A, "cycle.test", new Date(t0.getTime() + (day + 0.5) * DAY));
      if (day === 6) {
        if (again.kind !== "claimed") throw new Error("unexpected");
        expect(again.row.id).toBe(first.row.id);
        expect(again.row.createdAt.getTime()).toBe(t0.getTime());
      } else {
        // Day 12.5: lapsed on day 7, so A is in its cooldown.
        expect(again.kind).toBe("cooldown");
      }
    }
    // On day 8 another tenant takes it at once.
    expect((await claim(B, "cycle.test", new Date(t0.getTime() + 8 * DAY))).kind).toBe("claimed");
  });

  it("refuse the previous holder during the cooldown after a lapse, then give it a fresh reservation", async () => {
    const t0 = new Date(Date.now() - 30 * DAY);
    const first = await claim(A, "cool.test", t0);
    if (first.kind !== "claimed") throw new Error("unexpected");
    expect((await claim(A, "cool.test", new Date(t0.getTime() + 8 * DAY))).kind).toBe("cooldown");
    expect((await claim(A, "cool.test", new Date(t0.getTime() + 13 * DAY))).kind).toBe("cooldown");
    const renewedAt = new Date(t0.getTime() + 15 * DAY);
    const renewed = await claim(A, "cool.test", renewedAt);
    if (renewed.kind !== "claimed") throw new Error("unexpected");
    expect(renewed.row.id).not.toBe(first.row.id);
    expect(renewed.row.createdAt.getTime()).toBe(renewedAt.getTime());
    expect((await claim(B, "cool.test", new Date(renewedAt.getTime() + DAY))).kind).toBe("taken");
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
    }, 20));
    const vmId = newVmId();
    await liveVm(A, vmId);
    const rule = (domain: string): TlsRuleRow => ({
      id: newTlsRuleId(), tenantId: A, upstreamId: UpstreamId.make(`tls-${domain}`), domain, vmIds: [vmId], forwardAuthId: fwa,
      spec: { domain, protocol: "http", direction: "ingress", source: { public: true }, destination: { vmId, port: 3000 }, forwardAuthId: fwa, match: null, headerNames: [], description: null },
      createdBy: "user:test", createdAt: now, updatedAt: now,
    });
    for (const domain of ["example.com", "www.example.com", "*.example.com", "notexample.com"]) expect(await store((s) => s.insertTlsRule(rule(domain), 100, null))).toBe(true);
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

describe("orphaned rules, conditional release and atomic budgets", () => {
  it("count, list and release around a rule whose VM was deleted as if it were gone", async () => {
    const domain = await verified(A, "orphan.test");
    if (domain === null) throw new Error("not verified");
    const vmId = newVmId();
    await liveVm(A, vmId);
    const fwa = newForwardAuthId();
    const rule = ruleOn(A, "app.orphan.test", vmId, fwa);
    expect(await store((s) => s.insertTlsRule(rule, 100, "orphan.test"))).toBe(true);
    expect((await store((s) => s.deleteDomain(A, domain.id))).kind).toBe("in_use");
    await deleteVm(vmId);
    expect(await store((s) => s.countTlsRules(A))).toBe(0);
    expect(await store((s) => s.countTlsRulesUnder(A, "orphan.test"))).toBe(0);
    expect(await store((s) => s.countTlsRulesUsingForwardAuth(A, fwa))).toBe(0);
    expect(await store((s) => s.tlsRuleOrphaned(A, rule.id))).toBe(true);
    expect(await store((s) => s.tlsRuleOrphaned(B, rule.id))).toBe(false);
    expect((await store((s) => s.listOrphanedTlsRules(A, vmId))).map((row) => row.id)).toEqual([rule.id]);
    expect(await store((s) => s.listOrphanedTlsRules(A, newVmId()))).toEqual([]);
    expect(await store((s) => s.listOrphanedTlsRules(B, null))).toEqual([]);
    const released = await store((s) => s.deleteDomain(A, domain.id));
    expect(released.kind).toBe("released");
    expect((await store((s) => s.deleteDomain(A, domain.id))).kind).toBe("missing");
  });

  it("a VM of another tenant never keeps a rule live", async () => {
    const vmId = newVmId();
    await liveVm(B, vmId);
    expect(await store((s) => s.insertTlsRule(ruleOn(A, "x.test", vmId), 100, null))).toBe(true);
    expect(await store((s) => s.countTlsRules(A))).toBe(0);
  });

  it("insert a rule only under the budget of live rules and while its cover is still verified", async () => {
    const vmId = newVmId();
    await liveVm(A, vmId);
    expect(await store((s) => s.insertTlsRule(ruleOn(A, "a.cover.test", vmId), 100, "cover.test"))).toBe(false);
    await verified(A, "cover.test");
    expect(await store((s) => s.insertTlsRule(ruleOn(A, "a.cover.test", vmId), 100, "cover.test"))).toBe(true);
    expect(await store((s) => s.insertTlsRule(ruleOn(B, "b.cover.test", vmId), 100, "cover.test"))).toBe(false);
    expect(await store((s) => s.insertTlsRule(ruleOn(A, "b.cover.test", vmId), 1, null))).toBe(false);
    // An orphan frees its budget slot.
    await deleteVm(vmId);
    const next = newVmId();
    await liveVm(A, next);
    expect(await store((s) => s.insertTlsRule(ruleOn(A, "b.cover.test", next), 1, null))).toBe(true);
  });

  it("insert forward-auth checks and pending verifications only under their budgets", async () => {
    const now = new Date();
    const fa = (n: number) => ({
      id: newForwardAuthId(), tenantId: A, upstreamId: UpstreamId.make(`fa-b${n}`), url: "https://auth.example.com/", timeoutMs: 1500,
      headerNames: [], authResponseHeaders: [], protectedCookies: [], createdBy: "user:test", createdAt: now, updatedAt: now,
    });
    expect(await store((s) => s.insertForwardAuth(fa(1), 1))).toBe(true);
    expect(await store((s) => s.insertForwardAuth(fa(2), 1))).toBe(false);
    expect(await store((s) => s.countForwardAuths(A))).toBe(1);
    const dv = (n: number) => ({
      id: newDomainVerificationId(), tenantId: A, domain: `b${n}.test`, upstreamId: UpstreamId.make(`dv-b${n}`),
      recordName: `_challenge.b${n}.test`, code: "code", createdBy: "user:test", createdAt: now, verifiedAt: null,
    });
    expect(await store((s) => s.insertVerification(dv(1), 1))).toBe(true);
    expect(await store((s) => s.insertVerification(dv(2), 1))).toBe(false);
    expect(await store((s) => s.countPendingVerifications(A))).toBe(1);
  });
});
