/**
 * Fakes for domains and TLS (cx-b4h.6): an in-memory DomainStore with the same
 * semantics as the SQL store (src/db/domains.ts), and the provider routes
 * fake-upstream.ts does not serve: verifications, certificates, creating,
 * reading and deleting TLS rules, and forward-auth configurations. TLS rules
 * live in fake-upstream's shared `tlsRules` map, so the existing proxy
 * replacement route sees them too. Like the real provider, these resources
 * are account-wide: the fake knows nothing about tenants.
 */
import { Effect, Layer, Redacted } from "effect";
import { DomainStore, type DomainOwner, type DomainRow, type DomainStoreService, type ForwardAuthRow, type TlsRuleRow, type VerificationRow } from "../../src/db/domains.ts";
import { domainPolicyLayer, type DomainPolicyConfig } from "../../src/domain/domains.ts";
import { makeUpstreamDomains } from "../../src/upstream/live-domains.ts";
import { UpstreamDomains } from "../../src/upstream/domains.ts";
import type { FakeUpstream } from "./fake-upstream.ts";

const UPSTREAM_URL = "https://upstream.test";
const UPSTREAM_KEY = "upstream-test-key";

interface FakeChallenge {
  readonly id: string;
  readonly domain: string;
  readonly recordName: string;
  readonly code: string;
  verified: boolean;
}

export interface FakeCertificate {
  readonly domain: string;
  readonly wildcard: boolean;
  readonly active: boolean;
  readonly notAfter: string;
  readonly generation: number;
}

const below = (domain: string, base: string) => domain.length > base.length + 1 && domain.endsWith(`.${base}`);

/** Whether `vmId` is a live VM of `tenant` (the harness answers from its ownership rows). */
export type VmLive = (tenant: string, vmId: string) => boolean;

export function makeMemoryDomainStore(vmLive: VmLive = () => true) {
  const domains: DomainRow[] = [];
  const verifications: VerificationRow[] = [];
  const forwardAuths: ForwardAuthRow[] = [];
  const rules: TlsRuleRow[] = [];
  const replace = <T extends { readonly id: string }>(list: T[], next: T) => {
    const index = list.findIndex((row) => row.id === next.id);
    if (index >= 0) list[index] = next;
  };
  const remove = <T>(list: T[], keep: (row: T) => boolean) => {
    const kept = list.filter(keep);
    list.splice(0, list.length, ...kept);
  };
  const liveRule = (row: TlsRuleRow) => row.vmIds.every((vmId) => vmLive(row.tenantId, vmId));
  const under = (row: TlsRuleRow, domain: string) => row.domain === domain || below(row.domain, domain);
  const store: DomainStoreService = {
    claimDomain: (tenant, domain, candidate, createdBy, at, staleBefore, cooldownBefore) => Effect.sync(() => {
      const current = domains.find((row) => row.domain === domain);
      if (current === undefined) {
        const row: DomainRow = { id: candidate, tenantId: tenant, domain, createdBy, createdAt: at, verifiedAt: null };
        domains.push(row);
        return { kind: "claimed", row, displaced: [] } as const;
      }
      if (current.verifiedAt !== null) return current.tenantId === tenant ? { kind: "verified", row: current } as const : { kind: "taken" } as const;
      if (current.tenantId !== tenant && current.createdAt >= staleBefore) return { kind: "taken" } as const;
      const own = current.tenantId === tenant;
      // The tenant's own lapsed reservation cannot be re-claimed until its cooldown passed.
      if (own && current.createdAt < staleBefore && current.createdAt >= cooldownBefore) return { kind: "cooldown", row: current } as const;
      // The tenant's own live reservation is never refreshed; another tenant's lapsed one (or the tenant's own past
      // its cooldown) is taken over with a new id.
      const row: DomainRow = own && current.createdAt >= staleBefore ? current : { ...current, id: candidate, tenantId: tenant, createdBy, createdAt: at };
      domains[domains.indexOf(current)] = row;
      const displaced = verifications.filter((candidateRow) => candidateRow.domain === domain && candidateRow.tenantId !== tenant && candidateRow.verifiedAt === null);
      remove(verifications, (candidateRow) => !displaced.includes(candidateRow));
      return { kind: "claimed", row, displaced } as const;
    }),
    backOutFreshClaim: (tenant, id) => Effect.sync(() => {
      const current = domains.find((row) => row.tenantId === tenant && row.id === id && row.verifiedAt === null);
      if (current === undefined || verifications.some((row) => row.tenantId === tenant && row.domain === current.domain)) return;
      remove(domains, (row) => row !== current);
    }),
    markDomainVerified: (tenant, domain, at) => Effect.sync(() => {
      const current = domains.find((row) => row.tenantId === tenant && row.domain === domain);
      if (current === undefined) return null;
      const row: DomainRow = { ...current, verifiedAt: current.verifiedAt ?? at };
      replace(domains, row);
      return row;
    }),
    listDomains: (tenant) => Effect.sync(() => domains.filter((row) => row.tenantId === tenant && row.verifiedAt !== null)),
    findDomain: (tenant, id) => Effect.sync(() => domains.find((row) => row.tenantId === tenant && row.id === id && row.verifiedAt !== null) ?? null),
    deleteDomain: (tenant, id) => Effect.sync(() => {
      const row = domains.find((candidate) => candidate.tenantId === tenant && candidate.id === id && candidate.verifiedAt !== null);
      if (row === undefined) return { kind: "missing" } as const;
      if (rules.some((rule) => rule.tenantId === tenant && under(rule, row.domain) && liveRule(rule))) return { kind: "in_use" } as const;
      remove(domains, (candidate) => candidate !== row);
      const released = verifications.filter((candidate) => candidate.tenantId === tenant && candidate.domain === row.domain);
      remove(verifications, (candidate) => !released.includes(candidate));
      return { kind: "released", row, verifications: released } as const;
    }),
    verifiedOwners: (names) => Effect.sync((): ReadonlyArray<DomainOwner> =>
      domains.filter((row) => row.verifiedAt !== null && names.includes(row.domain)).map((row) => ({ domain: row.domain, tenantId: row.tenantId }))),
    verifiedBelow: (base) => Effect.sync((): ReadonlyArray<DomainOwner> =>
      domains.filter((row) => row.verifiedAt !== null && below(row.domain, base)).map((row) => ({ domain: row.domain, tenantId: row.tenantId }))),
    insertVerification: (row, limit) => Effect.sync(() => {
      if (verifications.filter((candidate) => candidate.tenantId === row.tenantId && candidate.verifiedAt === null).length >= limit) return false;
      verifications.push(row);
      return true;
    }),
    listVerifications: (tenant, state) => Effect.sync(() => verifications.filter((row) =>
      row.tenantId === tenant && (state === null || (state === "verified") === (row.verifiedAt !== null))).reverse()),
    findVerification: (tenant, id) => Effect.sync(() => verifications.find((row) => row.tenantId === tenant && row.id === id) ?? null),
    markVerificationVerified: (tenant, id, at) => Effect.sync(() => {
      const row = verifications.find((candidate) => candidate.tenantId === tenant && candidate.id === id);
      if (row !== undefined) replace(verifications, { ...row, verifiedAt: row.verifiedAt ?? at });
    }),
    deletePendingVerification: (tenant, id) => Effect.sync(() => {
      const before = verifications.length;
      remove(verifications, (row) => !(row.tenantId === tenant && row.id === id && row.verifiedAt === null));
      return verifications.length < before;
    }),
    countPendingVerifications: (tenant) => Effect.sync(() => verifications.filter((row) => row.tenantId === tenant && row.verifiedAt === null).length),
    insertForwardAuth: (row, limit) => Effect.sync(() => {
      if (forwardAuths.filter((candidate) => candidate.tenantId === row.tenantId).length >= limit) return false;
      forwardAuths.push(row);
      return true;
    }),
    listForwardAuths: (tenant) => Effect.sync(() => forwardAuths.filter((row) => row.tenantId === tenant).reverse()),
    findForwardAuth: (tenant, id) => Effect.sync(() => forwardAuths.find((row) => row.tenantId === tenant && row.id === id) ?? null),
    updateForwardAuth: (tenant, id, fields, at) => Effect.sync(() => {
      const row = forwardAuths.find((candidate) => candidate.tenantId === tenant && candidate.id === id);
      if (row === undefined) return null;
      const next: ForwardAuthRow = { ...row, ...fields, updatedAt: at };
      replace(forwardAuths, next);
      return next;
    }),
    deleteForwardAuth: (tenant, id) => Effect.sync(() => remove(forwardAuths, (row) => !(row.tenantId === tenant && row.id === id))),
    countForwardAuths: (tenant) => Effect.sync(() => forwardAuths.filter((row) => row.tenantId === tenant).length),
    insertTlsRule: (row, limit, cover) => Effect.sync(() => {
      if (rules.filter((candidate) => candidate.tenantId === row.tenantId && liveRule(candidate)).length >= limit) return false;
      if (cover !== null && !domains.some((candidate) => candidate.tenantId === row.tenantId && candidate.domain === cover && candidate.verifiedAt !== null)) return false;
      rules.push(row);
      return true;
    }),
    listTlsRules: (tenant) => Effect.sync(() => rules.filter((row) => row.tenantId === tenant).reverse()),
    findTlsRule: (tenant, id) => Effect.sync(() => rules.find((row) => row.tenantId === tenant && row.id === id) ?? null),
    updateTlsRule: (tenant, id, fields, at) => Effect.sync(() => {
      const row = rules.find((candidate) => candidate.tenantId === tenant && candidate.id === id);
      if (row === undefined) return null;
      const next: TlsRuleRow = { ...row, ...fields, updatedAt: at };
      replace(rules, next);
      return next;
    }),
    deleteTlsRule: (tenant, id) => Effect.sync(() => remove(rules, (row) => !(row.tenantId === tenant && row.id === id))),
    countTlsRules: (tenant) => Effect.sync(() => rules.filter((row) => row.tenantId === tenant && liveRule(row)).length),
    countTlsRulesUsingForwardAuth: (tenant, id) => Effect.sync(() => rules.filter((row) => row.tenantId === tenant && row.forwardAuthId === id && liveRule(row)).length),
    countTlsRulesUnder: (tenant, domain) => Effect.sync(() => rules.filter((row) => row.tenantId === tenant && under(row, domain) && liveRule(row)).length),
    listTlsRulesUnder: (tenant, domain) => Effect.sync(() => rules.filter((row) => row.tenantId === tenant && under(row, domain) && liveRule(row))),
    listOrphanedTlsRules: (tenant, vmId) => Effect.sync(() => rules.filter((row) => row.tenantId === tenant && (vmId === null || row.vmIds.includes(vmId)) && !liveRule(row))),
    tlsRuleOrphaned: (tenant, id) => Effect.sync(() => rules.some((row) => row.tenantId === tenant && row.id === id && !liveRule(row))),
  };
  return { store, domains, verifications, forwardAuths, rules };
}

export function makeDomainFakes(provider: FakeUpstream, policy: DomainPolicyConfig = {}, vmLive?: VmLive) {
  const memory = makeMemoryDomainStore(vmLive);
  const challenges = new Map<string, FakeChallenge>();
  /** TXT records "published" at a DNS host: recordName -> values. */
  const txt = new Map<string, Set<string>>();
  /** Domains whose `_acme-challenge` is delegated, so a wildcard certificate can be issued. */
  const delegated = new Set<string>();
  const certificates: FakeCertificate[] = [];
  const forwardAuths = new Map<string, Record<string, unknown>>();
  /** Challenge id -> the challenge id a verify of it names as `verifiedBy` (default: itself). */
  const verifiers = new Map<string, string>();
  /** TLS rule ids this fake created; the proxy replacement route in fake-upstream.ts owns the rest. */
  const ownRules = new Set<string>();

  const json = (body: unknown, status = 200) => Response.json(body, { status });
  const missing = () => json({ code: "NOT_FOUND", message: "not found" }, 404);

  const upstream = async (request: Request): Promise<Response | null> => {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method;
    const ruleId = /^\/v5\/tls\/(?!forward-auth(?:\/|$))([^/]+)$/u.exec(path)?.[1];
    const ours =
      path === "/v5/verifications" || path.startsWith("/v5/verifications/") || path.startsWith("/v5/certificates")
      || path === "/v5/tls/forward-auth" || path.startsWith("/v5/tls/forward-auth/")
      || (path === "/v5/tls" && method === "POST")
      || (ruleId !== undefined && (method === "GET" || method === "DELETE" || (method === "PUT" && ownRules.has(decodeURIComponent(ruleId)))));
    if (!ours) return null;
    const raw = request.body === null ? null : new Uint8Array(await request.arrayBuffer());
    const body: unknown = raw === null || raw.length === 0 ? null : JSON.parse(new TextDecoder().decode(raw));
    provider.calls.push({ method, path, search: url.searchParams, json: body, bytes: raw });
    if (request.headers.get("authorization") !== `Bearer ${UPSTREAM_KEY}`) return json({ code: "UNAUTHORIZED", message: "bad key" }, 401);
    const record = typeof body === "object" && body !== null ? Object.fromEntries(Object.entries(body)) : {};

    if (path === "/v5/verifications" && method === "POST") {
      const domain = String(record["domain"] ?? "");
      const challenge: FakeChallenge = { id: `dv-${crypto.randomUUID()}`, domain, recordName: `_challenge.${domain}`, code: crypto.randomUUID(), verified: false };
      challenges.set(challenge.id, challenge);
      return json({ id: challenge.id, domain, recordName: challenge.recordName, verificationCode: challenge.code, state: "pending", createdAt: new Date().toISOString() });
    }
    const verification = /^\/v5\/verifications\/([^/]+)$/u.exec(path)?.[1];
    if (verification !== undefined) {
      const challenge = challenges.get(decodeURIComponent(verification));
      if (challenge === undefined) return missing();
      if (method === "PUT") {
        if (!challenge.verified && !(txt.get(challenge.recordName)?.has(challenge.code) ?? false)) return json({ code: "VERIFICATION_FAILED", message: "no record" }, 400);
        challenge.verified = true;
        return json({ domain: challenge.domain, createdAt: new Date().toISOString(), verifiedBy: verifiers.get(challenge.id) ?? challenge.id });
      }
      if (method === "DELETE") {
        if (challenge.verified) return json({ code: "CONFLICT", message: "verified" }, 409);
        challenges.delete(challenge.id);
        return new Response(null, { status: 204 });
      }
      return missing();
    }
    if (path === "/v5/certificates" && method === "GET") return json({ certificates });
    if (path === "/v5/certificates/wildcard" && method === "POST") {
      const domain = String(record["domain"] ?? "");
      if (!delegated.has(domain)) return json({ code: "BAD_REQUEST", message: "not delegated" }, 400);
      const certificate: FakeCertificate = { domain, wildcard: true, active: false, notAfter: "2027-01-01T00:00:00Z", generation: 1 };
      certificates.push(certificate);
      return json(certificate);
    }
    if (path === "/v5/tls" && method === "POST") {
      const id = `tls-${crypto.randomUUID()}`;
      ownRules.add(id);
      provider.tlsRules.set(id, { ...record, id });
      return json({ ...record, id, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() });
    }
    if (ruleId !== undefined) {
      const id = decodeURIComponent(ruleId);
      const rule = provider.tlsRules.get(id);
      if (rule === undefined) return missing();
      if (method === "GET") return json(rule);
      if (method === "DELETE") {
        provider.tlsRules.delete(id);
        return new Response(null, { status: 204 });
      }
      provider.tlsRules.set(id, { ...record, id });
      return json({ ...record, id });
    }
    if (path === "/v5/tls/forward-auth" && method === "POST") {
      const id = `fa-${crypto.randomUUID()}`;
      forwardAuths.set(id, { ...record, id });
      return json({ ...record, id, accountId: "account", redacted: true });
    }
    const forwardAuth = /^\/v5\/tls\/forward-auth\/([^/]+)$/u.exec(path)?.[1];
    if (forwardAuth !== undefined) {
      const id = decodeURIComponent(forwardAuth);
      if (!forwardAuths.has(id)) return missing();
      if (method === "PUT") {
        forwardAuths.set(id, { ...record, id });
        return json({ ...record, id });
      }
      if (method === "DELETE") {
        const used = [...provider.tlsRules.values()].some((rule) => JSON.stringify(rule["forwardAuth"] ?? null) === JSON.stringify({ id }));
        if (used) return json({ code: "CONFLICT", message: "in use" }, 409);
        forwardAuths.delete(id);
        return new Response(null, { status: 204 });
      }
    }
    return missing();
  };

  const layer = (fetch: (request: Request) => Promise<Response>) =>
    Layer.mergeAll(
      Layer.succeed(DomainStore, memory.store),
      Layer.succeed(UpstreamDomains, makeUpstreamDomains({ baseUrl: UPSTREAM_URL, apiKey: Redacted.make(UPSTREAM_KEY), environment: "local", fetch: (request) => fetch(request) })),
      domainPolicyLayer(policy),
    );

  return {
    upstream,
    layer,
    /** The cmux tables, as the database would hold them. */
    rows: memory,
    challenges,
    forwardAuths,
    certificates,
    /** Publishes a TXT record at a DNS host, as the tenant would. */
    publishTxt(name: string, value: string) {
      const values = txt.get(name) ?? new Set<string>();
      values.add(value);
      txt.set(name, values);
    },
    /** Makes a verify of challenge `id` name `verifier` as the challenge that verified the domain. */
    nameVerifier(id: string, verifier: string) {
      verifiers.set(id, verifier);
    },
    /** Delegates `_acme-challenge.<domain>` so a wildcard certificate can be issued. */
    delegate(domain: string) {
      delegated.add(domain);
    },
  };
}

export type DomainFakes = ReturnType<typeof makeDomainFakes>;
