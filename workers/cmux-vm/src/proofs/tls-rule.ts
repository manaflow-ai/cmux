/**
 * Trusted module: domain reservation, TLS rule and forward-auth authority are
 * minted only here, after every tenant and policy check (cx-b4h.6).
 *
 * - VerifiableDomain: the caller's tenant reserved (or verified) this exact
 *   domain in cmux's table, so a provider challenge or wildcard certificate may
 *   be requested for it.
 * - TlsRuleAllowed: every VM the rule names is the caller's (with vm:network);
 *   an ingress name is a managed hostname of the caller's or under a domain the
 *   caller verified (the most specific verified domain decides); an egress
 *   destination is an HTTPS origin the deployment approved; a forward-auth
 *   check is the caller's. The evidence holds the provider body (with provider
 *   ids and write-only header values) and the public view; neither is on the
 *   proof itself.
 * - ForwardAuthAllowed: a bounded HTTPS URL and header set.
 * - StaleChallenges: provider challenges whose verification rows cmux's table
 *   just removed (a released domain, or another tenant's lapsed reservation
 *   taken over), so they may be withdrawn at the provider.
 */
import { defineProof, name, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option, Redacted } from "effect";
import type { TlsForwardAuthRequest, TlsRuleRequest, TlsRuleSpec } from "../api/domains.ts";
import { DomainStore, type DomainRow, type ForwardAuthFields, type VerificationRow } from "../db/domains.ts";
import type { StoreError } from "../db/sql.ts";
import {
  DomainPolicy,
  hostnameOf,
  isManagedHostnameOf,
  isUnder,
  managedSuffixOf,
  parentOf,
  ruleDomainOf,
  ruleDomainText,
  type RuleDomain,
} from "../domain/domains.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import { badRequest, conflict, missingScope, NotFound, vmNotFound, type BadRequest } from "../errors.ts";
import { parseVmId, type UpstreamId, type VmId } from "../lib/ids.ts";
import { parseForwardAuthId, type ForwardAuthId } from "../lib/domain-ids.ts";
import { httpsOrigin } from "../network-origin.ts";
import { TenantPolicy } from "../policy.ts";
import type { OwnershipStore } from "../db/stores.ts";
import { domainUpstreamIdOf, tenantOwnsForwardAuth, tenantVerifiedDomain } from "./domain-resource.ts";
import { keyHasScope } from "./key-has-scope.ts";
import { tenantOwnsVm, upstreamIdOf } from "./tenant-owns-resource.ts";
import { headersOf } from "./vm-network.ts";

/** How long an unverified reservation keeps other tenants out, counted from its first claim. */
export const RESERVATION_DAYS = 7;
/** After its reservation lapses, how long the previous holder may not claim the domain again. */
export const RECLAIM_COOLDOWN_DAYS = 7;
const DAY_MS = 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------- domains

export interface VerifiableDomain<C> extends Proof<"VerifiableDomain", [C]> {}
const Verifiable = defineProof("VerifiableDomain");
const verifiable = new WeakMap<object, string>();

export const verifiableDomainOf = <C>(proof: VerifiableDomain<C>): string => {
  const found = verifiable.get(proof);
  if (found === undefined) throw new Error("VerifiableDomain proof was not minted by src/proofs");
  return found;
};

const mintVerifiable = <C>(caller: Named<C, Principal>, domain: string): VerifiableDomain<C> => {
  const proof: VerifiableDomain<C> = Object.freeze({ ...Verifiable.prove(caller) });
  verifiable.set(proof, domain);
  return proof;
};

export interface StaleChallenges<C> extends Proof<"StaleChallenges", [C]> {}
const Stale = defineProof("StaleChallenges");
const staleEvidence = new WeakMap<object, ReadonlyArray<UpstreamId>>();

export const staleChallengeIdsOf = <C>(proof: StaleChallenges<C>): ReadonlyArray<UpstreamId> => {
  const found = staleEvidence.get(proof);
  if (found === undefined) throw new Error("StaleChallenges proof was not minted by src/proofs");
  return found;
};

/** Only pending challenges: a verified one is a permanent record at the provider. */
const mintStale = <C>(caller: Named<C, Principal>, removed: ReadonlyArray<VerificationRow>): StaleChallenges<C> => {
  const proof: StaleChallenges<C> = Object.freeze({ ...Stale.prove(caller) });
  staleEvidence.set(proof, Object.freeze(removed.filter((row) => row.verifiedAt === null).map((row) => row.upstreamId)));
  return proof;
};

/**
 * Reserves `raw` for the caller's tenant. Names under the managed zone are
 * never verifiable. Another tenant's verified domain, or its reservation newer
 * than seven days, is a conflict; so is the caller's own lapsed reservation
 * during its re-claim cooldown.
 */
export const reserveDomain = <C>(caller: Named<C, Principal>, raw: string, candidate: DomainRow["id"], at: Date) =>
  Effect.gen(function* () {
    if (keyHasScope(caller, "domain:write") === null) return yield* Effect.fail(missingScope("domain:write"));
    const domain = hostnameOf(raw.trim());
    if (domain === null) return yield* Effect.fail(badRequest("The domain must be a DNS name such as example.com"));
    const policy = yield* DomainPolicy;
    if (policy.managedZone !== null && (isUnder(domain, policy.managedZone) || isUnder(policy.managedZone, domain))) {
      return yield* Effect.fail(badRequest("Names under the managed zone need no verification and cannot be verified"));
    }
    const staleBefore = new Date(at.getTime() - RESERVATION_DAYS * DAY_MS);
    const cooldownBefore = new Date(at.getTime() - (RESERVATION_DAYS + RECLAIM_COOLDOWN_DAYS) * DAY_MS);
    const claim = yield* (yield* DomainStore).claimDomain(caller.value.tenantId, domain, candidate, actorRef(caller.value.actor), at, staleBefore, cooldownBefore);
    if (claim.kind === "taken") return yield* Effect.fail(conflict("This domain is reserved by another team"));
    if (claim.kind === "verified") return yield* Effect.fail(conflict("Your team already verified this domain"));
    if (claim.kind === "cooldown") {
      const until = new Date(claim.row.createdAt.getTime() + (RESERVATION_DAYS + RECLAIM_COOLDOWN_DAYS) * DAY_MS);
      return yield* Effect.fail(conflict(`Your team's reservation of this domain lapsed; your team can reserve it again after ${until.toISOString()}`));
    }
    // `fresh`: this request created the reservation row (a new claim or a takeover), so a failure may back it out.
    return { row: claim.row, fresh: claim.row.id === candidate, domain: mintVerifiable(caller, domain), stale: mintStale(caller, claim.displaced) };
  });

/**
 * Releases the caller's verified domain (refused while a live rule of the team routes under it), with the
 * pending challenges the release removed.
 */
export const releaseDomain = <C>(caller: Named<C, Principal>, id: DomainRow["id"]) =>
  Effect.gen(function* () {
    if (keyHasScope(caller, "domain:write") === null) return yield* Effect.fail(missingScope("domain:write"));
    const released = yield* (yield* DomainStore).deleteDomain(caller.value.tenantId, id);
    if (released.kind !== "released") return released;
    return { kind: "released" as const, row: released.row, stale: mintStale(caller, released.verifications) };
  });

/** A verified domain of the caller's, for a wildcard certificate; null when the caller cannot see it. */
export const verifiedDomainFor = <C>(caller: Named<C, Principal>, id: DomainRow["id"]) =>
  Effect.map(tenantVerifiedDomain(caller.value, id), (row) => (row === null ? null : { row, domain: mintVerifiable(caller, row.domain) }));

// ---------------------------------------------------------------- TLS rules

export interface TlsRuleAllowed<C> extends Proof<"TlsRuleAllowed", [C]> {}
const RuleAllowed = defineProof("TlsRuleAllowed");

interface RuleEvidence {
  /** The provider request body. Contains provider ids and write-only header values: never logged or returned. */
  readonly body: Readonly<Record<string, unknown>>;
  readonly spec: TlsRuleSpec;
  readonly domain: string;
  readonly vmIds: ReadonlyArray<string>;
  readonly forwardAuthId: string | null;
  /** The verified domain of the caller's that allows this name (null: a managed hostname, or egress). */
  readonly cover: string | null;
}
const ruleEvidence = new WeakMap<object, RuleEvidence>();

export const tlsRuleEvidenceOf = <C>(proof: TlsRuleAllowed<C>): RuleEvidence => {
  const found = ruleEvidence.get(proof);
  if (found === undefined) throw new Error("TlsRuleAllowed proof was not minted by src/proofs");
  return found;
};

const sameKeys = (value: object, keys: ReadonlyArray<string>): boolean => {
  const present = Object.entries(value).filter(([, entry]) => entry !== undefined).map(([key]) => key).sort();
  return present.length === keys.length && [...keys].sort().every((key, index) => present[index] === key);
};

const ROUTE_REFUSED = "Route only a managed hostname of your team or a domain your team verified (or one label below it)";

/**
 * Whether the caller's tenant may route `domain` publicly. Fails with a message that never says who else owns it.
 * Succeeds with the verified domain that allows it (the rule's cover), or null for a managed hostname.
 */
const mayRoute = (principal: Principal, domain: RuleDomain): Effect.Effect<string | null, BadRequest | StoreError, DomainStore | DomainPolicy> =>
  Effect.gen(function* () {
    const policy = yield* DomainPolicy;
    const store = yield* DomainStore;
    const zone = policy.managedZone;
    if (domain.kind === "exact") {
      const hostname = domain.hostname;
      if (zone !== null && isUnder(hostname, zone)) {
        const suffix = yield* managedSuffixOf(policy, principal.tenantId);
        if (suffix !== null && isManagedHostnameOf(hostname, suffix)) return null;
        return yield* Effect.fail(badRequest(`Managed hostnames of your team are one label ending in ${suffix ?? "the managed suffix"}`));
      }
      const parent = parentOf(hostname);
      const owners = yield* store.verifiedOwners(parent === null ? [hostname] : [hostname, parent]);
      const exact = owners.find((owner) => owner.domain === hostname);
      const decisive = exact ?? owners.find((owner) => owner.domain === parent);
      if (decisive !== undefined && decisive.tenantId === principal.tenantId) return decisive.domain;
      return yield* Effect.fail(badRequest(ROUTE_REFUSED));
    }
    const base = domain.base;
    if (zone !== null && (isUnder(base, zone) || isUnder(zone, base))) return yield* Effect.fail(badRequest("Wildcards over the managed zone are not offered"));
    const owners = yield* store.verifiedOwners([base]);
    if (!owners.some((owner) => owner.domain === base && owner.tenantId === principal.tenantId)) return yield* Effect.fail(badRequest(ROUTE_REFUSED));
    // A wildcard covers one label: it may not cover a child another team verified.
    const below = yield* store.verifiedBelow(base);
    if (below.some((owner) => owner.tenantId !== principal.tenantId && parentOf(owner.domain) === base)) return yield* Effect.fail(badRequest(ROUTE_REFUSED));
    return base;
  });

/** Resolves one of the caller's VMs for a rule, with vm:network; another tenant's is 404. */
const ownedVm = <C>(caller: Named<C, Principal>, raw: string): Effect.Effect<{ readonly id: VmId; readonly upstream: string }, NotFound | StoreError, OwnershipStore> =>
  Effect.gen(function* () {
    const parsed = parseVmId(raw);
    if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
    return yield* name(parsed.value, (vm) => Effect.gen(function* () {
      const owns = yield* tenantOwnsVm(caller, vm);
      if (owns === null) return yield* Effect.fail(vmNotFound());
      return { id: parsed.value, upstream: upstreamIdOf(owns) };
    }));
  });

const ownedForwardAuth = <C>(caller: Named<C, Principal>, raw: string): Effect.Effect<{ readonly id: ForwardAuthId; readonly upstream: string }, NotFound | StoreError, DomainStore> =>
  Effect.gen(function* () {
    const missing = () => new NotFound({ message: "Forward-auth check not found" });
    const parsed = parseForwardAuthId(raw);
    if (Option.isNone(parsed)) return yield* Effect.fail(missing());
    return yield* name(parsed.value, (config) => Effect.gen(function* () {
      const owned = yield* tenantOwnsForwardAuth(caller, config);
      if (owned === null) return yield* Effect.fail(missing());
      return { id: parsed.value, upstream: domainUpstreamIdOf(owned.owns) };
    }));
  });

/**
 * Checks one whole rule for the caller before any provider request. Requires
 * domain:write and vm:network. Private networks (vpcId), socks5, wildcards
 * other than one label over a verified domain, and transforms other than
 * headers are not offered.
 */
export const tlsRuleAllowed = <C>(caller: Named<C, Principal>, input: TlsRuleRequest) =>
  Effect.gen(function* () {
    if (keyHasScope(caller, "domain:write") === null) return yield* Effect.fail(missingScope("domain:write"));
    if (keyHasScope(caller, "vm:network") === null) return yield* Effect.fail(missingScope("vm:network"));
    const domain = ruleDomainOf(input.domain.trim());
    if (domain === null) return yield* Effect.fail(badRequest("The domain must be one DNS name, or *. followed by one"));
    const protocol = input.protocol ?? "http";
    const headers = input.headers === undefined ? null : headersOf(Redacted.value(input.headers));
    if (input.headers !== undefined && headers === null) {
      return yield* Effect.fail(badRequest("Headers must have bounded names and printable values, without framing headers"));
    }
    const headerEntries = headers === null ? [] : Object.entries(headers);
    if (headerEntries.length > 0 && protocol !== "http") return yield* Effect.fail(badRequest("Header transforms apply to http rules only"));
    const source = input.source;
    const destination = input.destination;
    const description = input.description ?? null;
    const match = input.match ?? null;

    let body: Record<string, unknown>;
    let spec: TlsRuleSpec;
    let vmIds: string[];
    let forwardAuthId: string | null = null;
    let cover: string | null = null;

    if (source.public === true && source.vmId === undefined) {
      // Ingress: the Internet dials the name and lands on one of the caller's VMs.
      if (!sameKeys(destination, ["vmId", "port"]) || destination.vmId === undefined || destination.port === undefined) {
        return yield* Effect.fail(badRequest("An ingress rule lands on one of your VMs: destination needs vmId and port only"));
      }
      if (match !== null) return yield* Effect.fail(badRequest("match applies to egress rules only"));
      if (input.forwardAuthId != null && protocol !== "http") return yield* Effect.fail(badRequest("Forward-auth checks apply to http rules only"));
      cover = yield* mayRoute(caller.value, domain);
      const vm = yield* ownedVm(caller, destination.vmId);
      const forwardAuth = input.forwardAuthId == null ? null : yield* ownedForwardAuth(caller, input.forwardAuthId);
      forwardAuthId = forwardAuth?.id ?? null;
      vmIds = [vm.id];
      body = {
        action: "allow", domain: ruleDomainText(domain), protocol, source: { public: true },
        destination: { vmId: vm.upstream, port: destination.port },
        ...(forwardAuth === null ? {} : { forwardAuth: { id: forwardAuth.upstream } }),
      };
      spec = {
        domain: ruleDomainText(domain), protocol, direction: "ingress", source: { public: true }, destination: { vmId: vm.id, port: destination.port },
        forwardAuthId: forwardAuth?.id ?? null, match: null, headerNames: headerEntries.map(([key]) => key), description,
      };
    } else if (source.vmId !== undefined && source.public === undefined) {
      // Egress: one of the caller's VMs dials the name; it reaches only an approved HTTPS origin.
      if (protocol !== "http") return yield* Effect.fail(badRequest("Egress rules are http only"));
      if (domain.kind !== "exact") return yield* Effect.fail(badRequest("Egress rules name one exact hostname"));
      if (input.forwardAuthId != null) return yield* Effect.fail(badRequest("Forward-auth checks apply to ingress rules only"));
      let origin: string | null = null;
      let target: Record<string, unknown>;
      let shown: TlsRuleSpec["destination"];
      if (destination.public === true && sameKeys(destination, ["public"])) {
        origin = httpsOrigin(`https://${domain.hostname}`);
        target = { public: true };
        shown = { public: true };
      } else if (sameKeys(destination, ["host", "port"]) && destination.host !== undefined && destination.port !== undefined) {
        const host = hostnameOf(destination.host);
        origin = host === null ? null : httpsOrigin(destination.port === 443 ? `https://${host}` : `https://${host}:${destination.port}`);
        target = { host, port: destination.port };
        shown = { host: host ?? destination.host, port: destination.port };
      } else {
        return yield* Effect.fail(badRequest("An egress rule's destination is public: true, or host and port"));
      }
      const policy = yield* TenantPolicy;
      if (origin === null || !policy.httpsProxyOrigins.has(origin)) return yield* Effect.fail(badRequest("The destination is not an HTTPS origin this deployment approved"));
      const vm = yield* ownedVm(caller, source.vmId);
      vmIds = [vm.id];
      body = {
        action: "allow", domain: domain.hostname, protocol, source: { vmId: vm.upstream }, destination: target,
        ...(match === null ? {} : { match }),
      };
      spec = {
        domain: domain.hostname, protocol, direction: "egress", source: { vmId: vm.id }, destination: shown,
        forwardAuthId: null, match, headerNames: headerEntries.map(([key]) => key), description,
      };
    } else {
      return yield* Effect.fail(badRequest("source is either public: true or one of your VMs (private networks are not offered)"));
    }
    if (headers !== null && headerEntries.length > 0) body = { ...body, transform: [{ headers }] };
    if (description !== null) body = { ...body, description };
    const proof: TlsRuleAllowed<C> = Object.freeze({ ...RuleAllowed.prove(caller) });
    ruleEvidence.set(proof, Object.freeze({ body: Object.freeze(body), spec, domain: spec.domain, vmIds, forwardAuthId, cover }));
    return proof;
  });

// ---------------------------------------------------------------- forward auth

export interface ForwardAuthAllowed<C> extends Proof<"ForwardAuthAllowed", [C]> {}
const AuthAllowed = defineProof("ForwardAuthAllowed");

interface ForwardAuthEvidence {
  /** The provider request body. Contains write-only header values. */
  readonly body: Readonly<Record<string, unknown>>;
  readonly fields: ForwardAuthFields;
}
const forwardAuthEvidence = new WeakMap<object, ForwardAuthEvidence>();

export const forwardAuthEvidenceOf = <C>(proof: ForwardAuthAllowed<C>): ForwardAuthEvidence => {
  const found = forwardAuthEvidence.get(proof);
  if (found === undefined) throw new Error("ForwardAuthAllowed proof was not minted by src/proofs");
  return found;
};

const TOKEN = /^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/u;
export const DEFAULT_FORWARD_AUTH_TIMEOUT_MS = 1500;

const distinctTokens = (values: ReadonlyArray<string>, lower: boolean): ReadonlyArray<string> | null => {
  const out: string[] = [];
  for (const value of values) {
    const normalized = lower ? value.toLowerCase() : value;
    if (!TOKEN.test(normalized) || out.includes(normalized)) return null;
    out.push(normalized);
  }
  return out;
};

export const forwardAuthAllowed = <C>(caller: Named<C, Principal>, input: TlsForwardAuthRequest) =>
  Effect.gen(function* () {
    if (keyHasScope(caller, "domain:write") === null) return yield* Effect.fail(missingScope("domain:write"));
    let url: URL | null = null;
    try {
      url = new URL(input.url);
    } catch {
      url = null;
    }
    if (url === null || url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.hash !== "" || hostnameOf(url.hostname) === null) {
      return yield* Effect.fail(badRequest("The forward-auth URL must be an absolute HTTPS URL on a DNS name"));
    }
    const headers = input.headers === undefined ? {} : headersOf(Redacted.value(input.headers));
    if (headers === null) return yield* Effect.fail(badRequest("Headers must have bounded names and printable values, without framing headers"));
    const authResponseHeaders = distinctTokens(input.authResponseHeaders ?? [], true);
    const protectedCookies = distinctTokens(input.protectedCookies ?? [], false);
    if (authResponseHeaders === null || protectedCookies === null) return yield* Effect.fail(badRequest("Header and cookie names must be distinct tokens"));
    const timeoutMs = input.timeoutMs ?? DEFAULT_FORWARD_AUTH_TIMEOUT_MS;
    const fields: ForwardAuthFields = { url: url.href, timeoutMs, headerNames: Object.keys(headers), authResponseHeaders, protectedCookies };
    const body = { url: url.href, headers, authResponseHeaders, protectedCookies, timeoutMs };
    const proof: ForwardAuthAllowed<C> = Object.freeze({ ...AuthAllowed.prove(caller) });
    forwardAuthEvidence.set(proof, Object.freeze({ body: Object.freeze(body), fields }));
    return proof;
  });
