/**
 * Trusted module: the only place a TenantOwnsDomainResource proof is minted.
 *
 * Verifications, TLS rules and forward-auth checks are provider resources the
 * whole provider account shares; the row in cmux's tables (migration 0018),
 * read keyed by the caller's tenant, is what makes one the caller's. Like
 * TenantOwnsResource, the provider id is kept in a module-private WeakMap keyed
 * by the exact proof object, so a copied or hand-built proof carries none.
 *
 * Visibility: a service key or agent key (requiredLabels) reaches none of these
 * resources, since they carry no labels; a resource-allowlisted key reaches
 * only the ids it lists.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import { DomainStore, type DomainRow, type ForwardAuthRow, type TlsRuleRow, type VerificationRow } from "../db/domains.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import type { UpstreamId } from "../lib/ids.ts";
import type { DomainId, DomainVerificationId, ForwardAuthId, TlsRuleId } from "../lib/domain-ids.ts";

const Owns = defineProof("TenantOwnsDomainResource");

/** The tenant of caller `C` owns the domain-family resource named `R`, and `C` may reach it. */
export interface TenantOwnsDomainResource<C, R> extends Proof<"TenantOwnsDomainResource", [C, R]> {}

const evidence = new WeakMap<object, UpstreamId>();

/** The provider id this proof was minted for. A proof not minted here has none. */
export const domainUpstreamIdOf = <C, R>(proof: TenantOwnsDomainResource<C, R>): UpstreamId => {
  const upstreamId = evidence.get(proof);
  if (upstreamId === undefined) throw new Error("TenantOwnsDomainResource proof was not minted by src/proofs");
  return upstreamId;
};

/** A labelled key (service or agent) never reaches unlabelled tenant resources. */
export const domainConfined = (principal: Principal): boolean => principal.requiredLabels !== undefined;

/** Whether the caller may see this public id at all. */
export const seesDomainResource = (principal: Principal, id: string): boolean =>
  !domainConfined(principal) && (principal.resourceAllowlist === null || principal.resourceAllowlist.has(id));

/** A new resource would be invisible to a confined or allowlisted key, so those may not create one. */
export const mayCreateDomainResource = (principal: Principal): boolean => !domainConfined(principal) && principal.resourceAllowlist === null;

const mint = <C, R>(caller: Named<C, Principal>, resource: Named<R, unknown>, upstreamId: UpstreamId): TenantOwnsDomainResource<C, R> => {
  const proof: TenantOwnsDomainResource<C, R> = Object.freeze({ ...Owns.prove(caller, resource) });
  evidence.set(proof, upstreamId);
  return proof;
};

export interface Owned<C, R, Row> {
  readonly owns: TenantOwnsDomainResource<C, R>;
  readonly row: Row;
}

export const tenantOwnsVerification = <C, R>(
  caller: Named<C, Principal>,
  verification: Named<R, DomainVerificationId>,
): Effect.Effect<Owned<C, R, VerificationRow> | null, StoreError, DomainStore> => Effect.gen(function* () {
  if (!seesDomainResource(caller.value, verification.value)) return null;
  const row = yield* (yield* DomainStore).findVerification(caller.value.tenantId, verification.value);
  if (row === null || row.tenantId !== caller.value.tenantId) return null;
  return { owns: mint(caller, verification, row.upstreamId), row };
});

export const tenantOwnsTlsRule = <C, R>(
  caller: Named<C, Principal>,
  rule: Named<R, TlsRuleId>,
): Effect.Effect<Owned<C, R, TlsRuleRow> | null, StoreError, DomainStore> => Effect.gen(function* () {
  if (!seesDomainResource(caller.value, rule.value)) return null;
  const row = yield* (yield* DomainStore).findTlsRule(caller.value.tenantId, rule.value);
  if (row === null || row.tenantId !== caller.value.tenantId) return null;
  return { owns: mint(caller, rule, row.upstreamId), row };
});

export const tenantOwnsForwardAuth = <C, R>(
  caller: Named<C, Principal>,
  config: Named<R, ForwardAuthId>,
): Effect.Effect<Owned<C, R, ForwardAuthRow> | null, StoreError, DomainStore> => Effect.gen(function* () {
  if (!seesDomainResource(caller.value, config.value)) return null;
  const row = yield* (yield* DomainStore).findForwardAuth(caller.value.tenantId, config.value);
  if (row === null || row.tenantId !== caller.value.tenantId) return null;
  return { owns: mint(caller, config, row.upstreamId), row };
});

/**
 * System cleanup, not a read on the caller's behalf: the caller's tenant owns this TLS rule. Minted without the
 * key-visibility check (a service, agent or allowlisted key deleting a VM still cleans up the rules naming it),
 * because nothing about the rule is returned to the caller. Used only to delete rules orphaned by a VM delete or
 * left under a released domain; the tenant check is what keeps another tenant's provider rule out of reach.
 */
export const tenantTlsRuleForCleanup = <C, R>(
  caller: Named<C, Principal>,
  rule: Named<R, TlsRuleId>,
): Effect.Effect<Owned<C, R, TlsRuleRow> | null, StoreError, DomainStore> => Effect.gen(function* () {
  const row = yield* (yield* DomainStore).findTlsRule(caller.value.tenantId, rule.value);
  if (row === null || row.tenantId !== caller.value.tenantId) return null;
  return { owns: mint(caller, rule, row.upstreamId), row };
});

/** A verified domain has no provider id of its own; this is the same visibility rule without a proof. */
export const tenantVerifiedDomain = (principal: Principal, id: DomainId): Effect.Effect<DomainRow | null, StoreError, DomainStore> => Effect.gen(function* () {
  if (!seesDomainResource(principal, id)) return null;
  const row = yield* (yield* DomainStore).findDomain(principal.tenantId, id);
  return row !== null && row.tenantId === principal.tenantId && row.verifiedAt !== null ? row : null;
});
