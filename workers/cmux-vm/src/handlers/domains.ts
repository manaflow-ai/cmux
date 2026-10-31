/**
 * Domains, verifications, certificates, TLS rules and forward-auth checks
 * (cx-b4h.6). Same order as every handler: scope, then the tenant's rate limit,
 * then ownership through cmux's tables (another tenant's id is 404 and absent
 * from lists). Provider ids stay in proofs; header values never leave the
 * request that carried them.
 */
import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { CmuxVmApi } from "../api.ts";
import {
  Certificate,
  CertificateList,
  Domain,
  DomainDns,
  DomainList,
  DomainVerification,
  DomainVerificationList,
  TlsForwardAuth,
  TlsForwardAuthList,
  TlsRule,
  TlsRuleList,
  type TlsForwardAuthRequest,
  type TlsRuleRequest,
} from "../api/domains.ts";
import { DomainStore, type DomainRow, type ForwardAuthRow, type TlsRuleRow, type VerificationRow } from "../db/domains.ts";
import { ancestorsOf, DomainPolicy, managedSuffixOf, type DomainPolicyService } from "../domain/domains.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import { BadRequest, conflict, Forbidden, NotFound, QuotaExceeded, vmNotFound, type Conflict, type ServiceUnavailable } from "../errors.ts";
import { parseVmId } from "../lib/ids.ts";
import {
  newDomainId,
  newDomainVerificationId,
  newForwardAuthId,
  newTlsRuleId,
  parseDomainId,
  parseDomainVerificationId,
  parseForwardAuthId,
  parseTlsRuleId,
} from "../lib/domain-ids.ts";
import {
  domainConfined,
  mayCreateDomainResource,
  type Owned,
  seesDomainResource,
  tenantOwnsForwardAuth,
  tenantOwnsTlsRule,
  tenantOwnsVerification,
  tenantVerifiedDomain,
} from "../proofs/domain-resource.ts";
import { tenantOwnsVm } from "../proofs/tenant-owns-resource.ts";
import { forwardAuthAllowed, forwardAuthEvidenceOf, releaseDomain, reserveDomain, tlsRuleAllowed, tlsRuleEvidenceOf, verifiedDomainFor } from "../proofs/tls-rule.ts";
import type { UpstreamError } from "../upstream/client.ts";
import { UpstreamDomains } from "../upstream/domains.ts";
import { audited, dependencyDown, withCaller } from "./common.ts";
import { forgetOrphanedTlsRules, forgetTlsRules } from "./tls-rule-cleanup.ts";

/** Per-tenant budgets: these are configuration records, not compute. */
export const DOMAIN_LIMITS = { pendingVerifications: 20, tlsRules: 100, forwardAuths: 20 } as const;

const now = Effect.map(Clock.currentTimeMillis, (ms) => new Date(ms));

const domainMissing = () => new NotFound({ message: "Domain not found" });
const verificationMissing = () => new NotFound({ message: "Domain verification not found" });
const ruleMissing = () => new NotFound({ message: "TLS rule not found" });
const forwardAuthMissing = () => new NotFound({ message: "Forward-auth check not found" });

const refuseConfinedCreate = (principal: Principal) =>
  mayCreateDomainResource(principal)
    ? Effect.void
    : Effect.fail(new Forbidden({ message: "Service keys, agent keys and resource-allowlisted keys cannot create domains, TLS rules or forward-auth checks" }));

const overBudget = (what: string, limit: number) => new QuotaExceeded({ message: `At most ${limit} ${what} per team` });
const coverLost = () => new BadRequest({ message: "Your team no longer holds the verified domain this name is under" });

/** Whether the tenant still holds `cover` as a verified domain (null: the rule needs none). */
const holdsCover = (tenantId: Principal["tenantId"], cover: string | null) => Effect.gen(function* () {
  if (cover === null) return true;
  const owners = yield* (yield* DomainStore).verifiedOwners([cover]);
  return owners.some((owner) => owner.tenantId === tenantId);
});

/** Whether a rule on `ruleDomain` is still allowed by a verified domain of the tenant (the most specific owner deciding). */
const stillCovered = (tenantId: Principal["tenantId"], ruleDomain: string) => Effect.gen(function* () {
  const base = ruleDomain.startsWith("*.") ? ruleDomain.slice(2) : ruleDomain;
  const candidates = ruleDomain.startsWith("*.") ? [base] : ancestorsOf(base).slice(0, 2);
  const owners = yield* (yield* DomainStore).verifiedOwners(candidates);
  const decisive = candidates.map((candidate) => owners.find((owner) => owner.domain === candidate)).find((owner) => owner !== undefined);
  return decisive !== undefined && decisive.tenantId === tenantId;
});

/** Store and provider failures answer 503 and log only the operation name. */
const stored = <A, E, R>(operation: string, effect: Effect.Effect<A, E, R>) =>
  effect.pipe(Effect.catchTags({ StoreError: dependencyDown(operation) }));
const upstreamDown = (operation: string) => dependencyDown(`upstream.${operation}`);

const domainView = (row: DomainRow, policy: DomainPolicyService) =>
  new Domain({
    id: row.id,
    domain: row.domain,
    verifiedAt: (row.verifiedAt ?? row.createdAt).toISOString(),
    dns: new DomainDns({
      routing: policy.edgeHost === null ? null : { name: `*.${row.domain}`, type: "CNAME", value: policy.edgeHost },
      wildcardCertificate: policy.certificateNameserver === null ? null : { name: `_acme-challenge.${row.domain}`, type: "NS", value: policy.certificateNameserver },
    }),
  });

const verificationView = (row: VerificationRow) =>
  new DomainVerification({
    id: row.id,
    domain: row.domain,
    state: row.verifiedAt === null ? "pending" : "verified",
    record: { name: row.recordName, type: "TXT", value: row.code },
    createdAt: row.createdAt.toISOString(),
    verifiedAt: row.verifiedAt?.toISOString() ?? null,
  });

const ruleView = (row: TlsRuleRow) => new TlsRule({ id: row.id, ...row.spec, createdAt: row.createdAt.toISOString(), updatedAt: row.updatedAt.toISOString() });

const forwardAuthView = (row: ForwardAuthRow) =>
  new TlsForwardAuth({
    id: row.id,
    url: row.url,
    headerNames: row.headerNames,
    authResponseHeaders: row.authResponseHeaders,
    protectedCookies: row.protectedCookies,
    timeoutMs: row.timeoutMs,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  });

/** A rule is visible only while the caller can still reach every VM it names (deleted VMs drop their rules). */
const reachesVms = <C>(caller: Named<C, Principal>, vmIds: ReadonlyArray<string>) =>
  Effect.forEach(vmIds, (raw) => {
    const parsed = parseVmId(raw);
    if (Option.isNone(parsed)) return Effect.succeed(false);
    return name(parsed.value, (vm) => Effect.map(tenantOwnsVm(caller, vm), (owns) => owns !== null));
  }).pipe(Effect.map((all) => all.every(Boolean)));

// ---------------------------------------------------------------- domains and verifications

const listDomains = () => withCaller("domain:read", "read", (caller) => stored("domains.list", Effect.gen(function* () {
  const policy = yield* DomainPolicy;
  if (domainConfined(caller.value)) return new DomainList({ items: [], managedSuffix: null });
  const rows = yield* (yield* DomainStore).listDomains(caller.value.tenantId);
  return new DomainList({
    items: rows.filter((row) => seesDomainResource(caller.value, row.id)).map((row) => domainView(row, policy)),
    managedSuffix: yield* managedSuffixOf(policy, caller.value.tenantId),
  });
})));

const findDomain = (principal: Principal, raw: string) => Effect.gen(function* () {
  const parsed = parseDomainId(raw);
  if (Option.isNone(parsed)) return yield* Effect.fail(domainMissing());
  const row = yield* tenantVerifiedDomain(principal, parsed.value);
  if (row === null) return yield* Effect.fail(domainMissing());
  return row;
});

const getDomain = (raw: string) => withCaller("domain:read", "read", (caller) => stored("domains.find", Effect.gen(function* () {
  return domainView(yield* findDomain(caller.value, raw), yield* DomainPolicy);
})));

const deleteDomain = (raw: string) => withCaller("domain:write", "write", (caller) => audited("domain.delete", parseDomainId(raw).pipe(Option.getOrNull),
  stored("domains.delete", Effect.gen(function* () {
    const row = yield* findDomain(caller.value, raw);
    const store = yield* DomainStore;
    // Rules orphaned by deleted VMs never block a release; clean them up at the provider first (best effort).
    yield* forgetOrphanedTlsRules(caller, null);
    const released = yield* releaseDomain(caller, row.id);
    if (released.kind === "missing") return yield* Effect.fail(domainMissing());
    if (released.kind === "in_use") return yield* Effect.fail(conflict("A TLS rule of your team still routes a name under this domain; delete it first"));
    // Pending challenges of the released domain would otherwise outlive it at the provider.
    yield* (yield* UpstreamDomains).withdrawStaleChallenges(released.stale);
    // A rule recorded while the release ran routes under a domain the team no longer holds: remove it.
    // (createTlsRule checks again after its insert; between the two checks every interleaving is caught.)
    const late: TlsRuleRow[] = [];
    for (const rule of yield* store.listTlsRulesUnder(caller.value.tenantId, released.row.domain)) {
      if (!(yield* stillCovered(caller.value.tenantId, rule.domain))) late.push(rule);
    }
    yield* forgetTlsRules(caller, late);
  }))));

const requestWildcardCertificate = (raw: string) => withCaller("domain:write", "write", (caller) => audited("domain.wildcard_certificate", parseDomainId(raw).pipe(Option.getOrNull),
  stored("domains.find", Effect.gen(function* () {
    const parsed = parseDomainId(raw);
    if (Option.isNone(parsed)) return yield* Effect.fail(domainMissing());
    const verified = yield* verifiedDomainFor(caller, parsed.value);
    if (verified === null) return yield* Effect.fail(domainMissing());
    const result = yield* (yield* UpstreamDomains).requestWildcard(verified.domain).pipe(Effect.catchAll(upstreamDown("requestWildcard")));
    if (result === "refused") {
      return yield* Effect.fail(new BadRequest({ message: `Delegate _acme-challenge.${verified.row.domain} to the certificate nameserver, then retry` }));
    }
    return new Certificate(result);
  }))));

const listCertificates = () => withCaller("domain:read", "read", (caller) => stored("certificates.list", Effect.gen(function* () {
  if (domainConfined(caller.value)) return new CertificateList({ items: [] });
  const certificates = yield* (yield* UpstreamDomains).listCertificates.pipe(Effect.catchAll(upstreamDown("listCertificates")));
  const store = yield* DomainStore;
  const names = [...new Set(certificates.flatMap((certificate) => ancestorsOf(certificate.domain.toLowerCase())))];
  const owners = new Map((yield* store.verifiedOwners(names)).map((owner) => [owner.domain, owner.tenantId]));
  const mine = new Map((yield* store.listDomains(caller.value.tenantId)).map((row) => [row.domain, row.id]));
  const items = certificates.filter((certificate) => {
    // The most specific verified domain above the certificate's name decides whose it is.
    const decisive = ancestorsOf(certificate.domain.toLowerCase()).find((candidate) => owners.has(candidate));
    if (decisive === undefined || owners.get(decisive) !== caller.value.tenantId) return false;
    const id = mine.get(decisive);
    return id !== undefined && seesDomainResource(caller.value, id);
  });
  return new CertificateList({ items: items.map((certificate) => new Certificate(certificate)) });
})));

const createDomainVerification = (domain: string) => withCaller("domain:write", "write", (caller) => audited("domain_verification.create", null,
  stored("verifications.create", Effect.gen(function* () {
    yield* refuseConfinedCreate(caller.value);
    const store = yield* DomainStore;
    if ((yield* store.countPendingVerifications(caller.value.tenantId)) >= DOMAIN_LIMITS.pendingVerifications) {
      return yield* Effect.fail(overBudget("pending domain verifications", DOMAIN_LIMITS.pendingVerifications));
    }
    const at = yield* now;
    const upstream = yield* UpstreamDomains;
    const reserved = yield* reserveDomain(caller, domain, newDomainId(), at);
    // Another team's lapsed reservation was taken over: its pending challenges can no longer verify anything.
    yield* upstream.withdrawStaleChallenges(reserved.stale);
    // Only a reservation this request created is backed out on failure; an older one keeps its first-claim lapse.
    const release = reserved.fresh ? store.backOutFreshClaim(caller.value.tenantId, reserved.row.id).pipe(Effect.ignore) : Effect.void;
    const challenge = yield* upstream.createVerification(reserved.domain).pipe(
      Effect.tapError(() => release),
      Effect.catchAll(upstreamDown("createVerification")),
    );
    const backOut = challenge.discard.pipe(Effect.zipRight(release));
    const row: VerificationRow = {
      id: newDomainVerificationId(), tenantId: caller.value.tenantId, domain: reserved.row.domain, upstreamId: challenge.upstreamId,
      recordName: challenge.recordName, code: challenge.code, createdBy: actorRef(caller.value.actor), createdAt: at, verifiedAt: null,
    };
    const budgetFull = () => overBudget("pending domain verifications", DOMAIN_LIMITS.pendingVerifications);
    // The budget holds at the insert itself; concurrent creates that all passed it back out together.
    const inserted = yield* store.insertVerification(row, DOMAIN_LIMITS.pendingVerifications).pipe(Effect.tapError(() => backOut));
    if (!inserted) return yield* backOut.pipe(Effect.zipRight(Effect.fail(budgetFull())));
    if ((yield* store.countPendingVerifications(caller.value.tenantId)) > DOMAIN_LIMITS.pendingVerifications) {
      yield* store.deletePendingVerification(caller.value.tenantId, row.id);
      return yield* backOut.pipe(Effect.zipRight(Effect.fail(budgetFull())));
    }
    return verificationView(row);
  })), (view) => view.id));

const listDomainVerifications = (state: "pending" | "verified" | undefined) => withCaller("domain:read", "read", (caller) => stored("verifications.list", Effect.gen(function* () {
  if (domainConfined(caller.value)) return new DomainVerificationList({ items: [] });
  const rows = yield* (yield* DomainStore).listVerifications(caller.value.tenantId, state ?? null);
  return new DomainVerificationList({ items: rows.filter((row) => seesDomainResource(caller.value, row.id)).map(verificationView) });
})));

const withVerification = <C, A, E, R>(caller: Named<C, Principal>, raw: string, k: <V>(owned: Owned<C, V, VerificationRow>) => Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const parsed = parseDomainVerificationId(raw);
    if (Option.isNone(parsed)) return yield* Effect.fail(verificationMissing());
    return yield* name(parsed.value, (verification) => Effect.gen(function* () {
      const owned = yield* tenantOwnsVerification(caller, verification);
      if (owned === null) return yield* Effect.fail(verificationMissing());
      return yield* k(owned);
    }));
  });

const getDomainVerification = (raw: string) => withCaller("domain:read", "read", (caller) => stored("verifications.find",
  withVerification(caller, raw, (owned) => Effect.succeed(verificationView(owned.row)))));

const verifyDomain = (raw: string) => withCaller("domain:write", "write", (caller) => audited("domain.verify", parseDomainVerificationId(raw).pipe(Option.getOrNull),
  stored("verifications.verify", withVerification(caller, raw, (owned) => Effect.gen(function* () {
    const store = yield* DomainStore;
    const policy = yield* DomainPolicy;
    const at = yield* now;
    const upstream = yield* UpstreamDomains;
    if (owned.row.verifiedAt === null) {
      // The provider may name another challenge of this team for the same domain as the one that verified it.
      const siblings = (yield* store.listVerifications(caller.value.tenantId, null))
        .filter((row) => row.domain === owned.row.domain && row.id !== owned.row.id)
        .map((row) => row.upstreamId);
      const result = yield* upstream.verifyDomain(owned.owns, siblings).pipe(Effect.catchAll(upstreamDown("verifyDomain")));
      if (result === "pending") return yield* Effect.fail(new BadRequest({ message: `The TXT record at ${owned.row.recordName} is not visible yet; publish it and retry` }));
      if (result === "gone") return yield* Effect.fail(verificationMissing());
    }
    const domain = yield* store.markDomainVerified(caller.value.tenantId, owned.row.domain, at);
    if (domain === null) {
      // This challenge can never be recorded: withdraw it at the provider (best effort) and forget it.
      yield* upstream.deleteVerification(owned.owns).pipe(Effect.ignore);
      yield* store.deletePendingVerification(caller.value.tenantId, owned.row.id);
      return yield* Effect.fail(conflict("This domain is no longer reserved for your team; create a new verification"));
    }
    yield* store.markVerificationVerified(caller.value.tenantId, owned.row.id, at);
    return domainView(domain, policy);
  }))), (view) => view.id));

const deleteDomainVerification = (raw: string) => withCaller("domain:write", "write", (caller) => audited("domain_verification.delete", parseDomainVerificationId(raw).pipe(Option.getOrNull),
  stored("verifications.delete", withVerification(caller, raw, (owned) => Effect.gen(function* () {
    const permanent = () => conflict("A completed verification is a permanent record; release the domain instead");
    if (owned.row.verifiedAt !== null) return yield* Effect.fail(permanent());
    const result = yield* (yield* UpstreamDomains).deleteVerification(owned.owns).pipe(Effect.catchAll(upstreamDown("deleteVerification")));
    if (result === "verified") return yield* Effect.fail(conflict("This challenge already verified; call verify to record it"));
    const store = yield* DomainStore;
    // The reservation stays: it lapses seven days after the team's first claim, so withdrawing and re-creating a
    // challenge can never extend the hold.
    yield* store.deletePendingVerification(caller.value.tenantId, owned.row.id);
  })))));

export const domainsHandlers = HttpApiBuilder.group(CmuxVmApi, "domains", (handlers) => handlers
  .handle("listDomains", () => listDomains())
  .handle("getDomain", ({ path }) => getDomain(path.domainId))
  .handle("deleteDomain", ({ path }) => deleteDomain(path.domainId))
  .handle("requestWildcardCertificate", ({ path }) => requestWildcardCertificate(path.domainId))
  .handle("listCertificates", () => listCertificates())
  .handle("createDomainVerification", ({ payload }) => createDomainVerification(payload.domain))
  .handle("listDomainVerifications", ({ urlParams }) => listDomainVerifications(urlParams.state))
  .handle("getDomainVerification", ({ path }) => getDomainVerification(path.verificationId))
  .handle("verifyDomain", ({ path }) => verifyDomain(path.verificationId))
  .handle("deleteDomainVerification", ({ path }) => deleteDomainVerification(path.verificationId)));

// ---------------------------------------------------------------- TLS rules

/** Provider refusals of a checked rule: a duplicate is 409, anything it cannot serve is 400, a vanished VM 404. */
const ruleRefused = (operation: string) => (error: UpstreamError): Effect.Effect<never, Conflict | BadRequest | NotFound | ServiceUnavailable> => {
  if (error.status === 409) return Effect.fail(conflict("A rule for this name, source and destination already exists"));
  if (error.status === 400) return Effect.fail(new BadRequest({ message: "The platform refused this rule" }));
  if (error.status === 404) return Effect.fail(vmNotFound());
  return upstreamDown(operation)(error);
};

/**
 * Resolves one of the caller's rules. `orphans`: a rule whose VM was deleted is reachable too (for delete only),
 * while a rule naming a live VM out of the key's reach stays 404.
 */
const withRule = <C, A, E, R>(caller: Named<C, Principal>, raw: string, k: <V>(owned: Owned<C, V, TlsRuleRow>) => Effect.Effect<A, E, R>, orphans = false) =>
  Effect.gen(function* () {
    const parsed = parseTlsRuleId(raw);
    if (Option.isNone(parsed)) return yield* Effect.fail(ruleMissing());
    return yield* name(parsed.value, (rule) => Effect.gen(function* () {
      const owned = yield* tenantOwnsTlsRule(caller, rule);
      if (owned === null) return yield* Effect.fail(ruleMissing());
      if (!(yield* reachesVms(caller, owned.row.vmIds))) {
        const orphaned = orphans && (yield* (yield* DomainStore).tlsRuleOrphaned(caller.value.tenantId, owned.row.id));
        if (!orphaned) return yield* Effect.fail(ruleMissing());
      }
      return yield* k(owned);
    }));
  });

const listTlsRules = (vmId: string | undefined) => withCaller("domain:read", "read", (caller) => stored("tlsRules.list", Effect.gen(function* () {
  if (domainConfined(caller.value)) return new TlsRuleList({ items: [] });
  const rows = yield* (yield* DomainStore).listTlsRules(caller.value.tenantId);
  const visible: TlsRule[] = [];
  for (const row of rows) {
    if (!seesDomainResource(caller.value, row.id) || (vmId !== undefined && !row.vmIds.includes(vmId))) continue;
    if (yield* reachesVms(caller, row.vmIds)) visible.push(ruleView(row));
  }
  return new TlsRuleList({ items: visible });
})));

const createTlsRule = (payload: TlsRuleRequest) => withCaller("domain:write", "write", (caller) => audited("tls_rule.create", null,
  stored("tlsRules.create", Effect.gen(function* () {
    yield* refuseConfinedCreate(caller.value);
    const store = yield* DomainStore;
    const tenantId = caller.value.tenantId;
    const budgetFull = () => overBudget("TLS rules", DOMAIN_LIMITS.tlsRules);
    // Rules orphaned by deleted VMs hold no budget; clean them up at the provider too (best effort).
    yield* forgetOrphanedTlsRules(caller, null);
    if ((yield* store.countTlsRules(tenantId)) >= DOMAIN_LIMITS.tlsRules) return yield* Effect.fail(budgetFull());
    const allowed = yield* tlsRuleAllowed(caller, payload);
    const evidence = tlsRuleEvidenceOf(allowed);
    const created = yield* (yield* UpstreamDomains).createTlsRule(allowed).pipe(Effect.catchAll(ruleRefused("createTlsRule")));
    const at = yield* now;
    const row: TlsRuleRow = {
      id: newTlsRuleId(), tenantId, upstreamId: created.upstreamId, domain: evidence.domain, spec: evidence.spec,
      vmIds: evidence.vmIds, forwardAuthId: evidence.forwardAuthId, createdBy: actorRef(caller.value.actor), createdAt: at, updatedAt: at,
    };
    // The insert itself re-checks the budget and that the team still holds the verified domain the name is under.
    const inserted = yield* store.insertTlsRule(row, DOMAIN_LIMITS.tlsRules, evidence.cover).pipe(Effect.tapError(() => created.discard));
    if (!inserted) {
      yield* created.discard;
      return yield* Effect.fail((yield* holdsCover(tenantId, evidence.cover)) ? budgetFull() : coverLost());
    }
    // Then once more after it: concurrent creates past the budget back out together, and a rule that raced a
    // release of its domain is removed (deleteDomain checks for the other order).
    const overflow = (yield* store.countTlsRules(tenantId)) > DOMAIN_LIMITS.tlsRules;
    const covered = yield* holdsCover(tenantId, evidence.cover);
    if (overflow || !covered) {
      yield* created.discard;
      yield* store.deleteTlsRule(tenantId, row.id);
      return yield* Effect.fail(covered ? budgetFull() : coverLost());
    }
    return ruleView(row);
  })), (view) => view.id));

const getTlsRule = (raw: string) => withCaller("domain:read", "read", (caller) => stored("tlsRules.find", withRule(caller, raw, (owned) => Effect.gen(function* () {
  const present = yield* (yield* UpstreamDomains).getTlsRule(owned.owns).pipe(Effect.catchAll(upstreamDown("getTlsRule")));
  if (present === "gone") {
    // The platform deletes a rule with the VM it names; forget it here too.
    yield* (yield* DomainStore).deleteTlsRule(caller.value.tenantId, owned.row.id);
    return yield* Effect.fail(ruleMissing());
  }
  return ruleView(owned.row);
}))));

const updateTlsRule = (raw: string, payload: TlsRuleRequest) => withCaller("domain:write", "write", (caller) => audited("tls_rule.update", parseTlsRuleId(raw).pipe(Option.getOrNull),
  stored("tlsRules.update", withRule(caller, raw, (owned) => Effect.gen(function* () {
    const allowed = yield* tlsRuleAllowed(caller, payload);
    const evidence = tlsRuleEvidenceOf(allowed);
    const store = yield* DomainStore;
    const result = yield* (yield* UpstreamDomains).updateTlsRule(owned.owns, allowed).pipe(Effect.catchAll(ruleRefused("updateTlsRule")));
    if (result === "gone") {
      yield* store.deleteTlsRule(caller.value.tenantId, owned.row.id);
      return yield* Effect.fail(ruleMissing());
    }
    const row = yield* store.updateTlsRule(caller.value.tenantId, owned.row.id,
      { domain: evidence.domain, spec: evidence.spec, vmIds: evidence.vmIds, forwardAuthId: evidence.forwardAuthId }, yield* now);
    if (row === null) return yield* Effect.fail(ruleMissing());
    if (!(yield* holdsCover(caller.value.tenantId, evidence.cover))) {
      // The domain was released while the rule changed to a name under it: the rule cannot stay.
      yield* forgetTlsRules(caller, [row]);
      return yield* Effect.fail(coverLost());
    }
    return ruleView(row);
  })))));

const deleteTlsRule = (raw: string) => withCaller("domain:write", "write", (caller) => audited("tls_rule.delete", parseTlsRuleId(raw).pipe(Option.getOrNull),
  stored("tlsRules.delete", withRule(caller, raw, (owned) => Effect.gen(function* () {
    // "gone" (the provider deleted it with its VM) still forgets it here.
    yield* (yield* UpstreamDomains).deleteTlsRule(owned.owns).pipe(Effect.catchAll(upstreamDown("deleteTlsRule")));
    yield* (yield* DomainStore).deleteTlsRule(caller.value.tenantId, owned.row.id);
  }), true))));

export const tlsRulesHandlers = HttpApiBuilder.group(CmuxVmApi, "tlsRules", (handlers) => handlers
  .handle("listTlsRules", ({ urlParams }) => listTlsRules(urlParams.vmId))
  .handle("createTlsRule", ({ payload }) => createTlsRule(payload))
  .handle("getTlsRule", ({ path }) => getTlsRule(path.ruleId))
  .handle("updateTlsRule", ({ path, payload }) => updateTlsRule(path.ruleId, payload))
  .handle("deleteTlsRule", ({ path }) => deleteTlsRule(path.ruleId)));

// ---------------------------------------------------------------- forward auth

const forwardAuthRefused = (operation: string) => (error: UpstreamError): Effect.Effect<never, BadRequest | ServiceUnavailable> =>
  error.status === 400 ? Effect.fail(new BadRequest({ message: "The platform refused this forward-auth configuration" })) : upstreamDown(operation)(error);

const withForwardAuth = <C, A, E, R>(caller: Named<C, Principal>, raw: string, k: <V>(owned: Owned<C, V, ForwardAuthRow>) => Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const parsed = parseForwardAuthId(raw);
    if (Option.isNone(parsed)) return yield* Effect.fail(forwardAuthMissing());
    return yield* name(parsed.value, (config) => Effect.gen(function* () {
      const owned = yield* tenantOwnsForwardAuth(caller, config);
      if (owned === null) return yield* Effect.fail(forwardAuthMissing());
      return yield* k(owned);
    }));
  });

const listTlsForwardAuths = () => withCaller("domain:read", "read", (caller) => stored("forwardAuths.list", Effect.gen(function* () {
  if (domainConfined(caller.value)) return new TlsForwardAuthList({ items: [] });
  const rows = yield* (yield* DomainStore).listForwardAuths(caller.value.tenantId);
  return new TlsForwardAuthList({ items: rows.filter((row) => seesDomainResource(caller.value, row.id)).map(forwardAuthView) });
})));

const createTlsForwardAuth = (payload: TlsForwardAuthRequest) => withCaller("domain:write", "write", (caller) => audited("tls_forward_auth.create", null,
  stored("forwardAuths.create", Effect.gen(function* () {
    yield* refuseConfinedCreate(caller.value);
    const store = yield* DomainStore;
    if ((yield* store.countForwardAuths(caller.value.tenantId)) >= DOMAIN_LIMITS.forwardAuths) {
      return yield* Effect.fail(overBudget("forward-auth checks", DOMAIN_LIMITS.forwardAuths));
    }
    const allowed = yield* forwardAuthAllowed(caller, payload);
    const created = yield* (yield* UpstreamDomains).createForwardAuth(allowed).pipe(Effect.catchAll(forwardAuthRefused("createForwardAuth")));
    const at = yield* now;
    const row: ForwardAuthRow = {
      id: newForwardAuthId(), tenantId: caller.value.tenantId, upstreamId: created.upstreamId, ...forwardAuthEvidenceOf(allowed).fields,
      createdBy: actorRef(caller.value.actor), createdAt: at, updatedAt: at,
    };
    const budgetFull = () => overBudget("forward-auth checks", DOMAIN_LIMITS.forwardAuths);
    const inserted = yield* store.insertForwardAuth(row, DOMAIN_LIMITS.forwardAuths).pipe(Effect.tapError(() => created.discard));
    if (!inserted) return yield* created.discard.pipe(Effect.zipRight(Effect.fail(budgetFull())));
    if ((yield* store.countForwardAuths(caller.value.tenantId)) > DOMAIN_LIMITS.forwardAuths) {
      yield* store.deleteForwardAuth(caller.value.tenantId, row.id);
      return yield* created.discard.pipe(Effect.zipRight(Effect.fail(budgetFull())));
    }
    return forwardAuthView(row);
  })), (view) => view.id));

const getTlsForwardAuth = (raw: string) => withCaller("domain:read", "read", (caller) => stored("forwardAuths.find",
  withForwardAuth(caller, raw, (owned) => Effect.succeed(forwardAuthView(owned.row)))));

const updateTlsForwardAuth = (raw: string, payload: TlsForwardAuthRequest) => withCaller("domain:write", "write", (caller) => audited("tls_forward_auth.update", parseForwardAuthId(raw).pipe(Option.getOrNull),
  stored("forwardAuths.update", withForwardAuth(caller, raw, (owned) => Effect.gen(function* () {
    const allowed = yield* forwardAuthAllowed(caller, payload);
    const store = yield* DomainStore;
    const result = yield* (yield* UpstreamDomains).updateForwardAuth(owned.owns, allowed).pipe(Effect.catchAll(forwardAuthRefused("updateForwardAuth")));
    if (result === "gone") {
      yield* store.deleteForwardAuth(caller.value.tenantId, owned.row.id);
      return yield* Effect.fail(forwardAuthMissing());
    }
    const row = yield* store.updateForwardAuth(caller.value.tenantId, owned.row.id, forwardAuthEvidenceOf(allowed).fields, yield* now);
    if (row === null) return yield* Effect.fail(forwardAuthMissing());
    return forwardAuthView(row);
  })))));

const deleteTlsForwardAuth = (raw: string) => withCaller("domain:write", "write", (caller) => audited("tls_forward_auth.delete", parseForwardAuthId(raw).pipe(Option.getOrNull),
  stored("forwardAuths.delete", withForwardAuth(caller, raw, (owned) => Effect.gen(function* () {
    const inUse = () => conflict("A TLS rule still uses this forward-auth check; change or delete the rule first");
    const store = yield* DomainStore;
    // A rule orphaned by a deleted VM does not use it any more: clean those up first (best effort at the provider).
    yield* forgetOrphanedTlsRules(caller, null);
    if ((yield* store.countTlsRulesUsingForwardAuth(caller.value.tenantId, owned.row.id)) > 0) return yield* Effect.fail(inUse());
    const result = yield* (yield* UpstreamDomains).deleteForwardAuth(owned.owns).pipe(Effect.catchAll(upstreamDown("deleteForwardAuth")));
    if (result === "in_use") return yield* Effect.fail(inUse());
    yield* store.deleteForwardAuth(caller.value.tenantId, owned.row.id);
  })))));

export const tlsForwardAuthHandlers = HttpApiBuilder.group(CmuxVmApi, "tlsForwardAuth", (handlers) => handlers
  .handle("listTlsForwardAuths", () => listTlsForwardAuths())
  .handle("createTlsForwardAuth", ({ payload }) => createTlsForwardAuth(payload))
  .handle("getTlsForwardAuth", ({ path }) => getTlsForwardAuth(path.forwardAuthId))
  .handle("updateTlsForwardAuth", ({ path, payload }) => updateTlsForwardAuth(path.forwardAuthId, payload))
  .handle("deleteTlsForwardAuth", ({ path }) => deleteTlsForwardAuth(path.forwardAuthId)));
