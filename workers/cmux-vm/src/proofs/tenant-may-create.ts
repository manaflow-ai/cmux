/**
 * Trusted module: the only place a TenantMayCreate proof is minted.
 *
 * Creation is gated by entitlement (billing) and quota. The resource kind is
 * part of the proof's kind, so a VM proof cannot authorize a snapshot. A
 * granted proof carries the quota reservation it holds; release it once the
 * new resource is recorded in the ownership table or the create failed.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Context, Data, Effect, Layer } from "effect";
import { OwnershipStore } from "../db/stores.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import type { ResourceKind, TenantId } from "../lib/ids.ts";
import { TenantLimits, type LimitsUnavailable } from "../limits/service.ts";
import { TenantPolicy } from "../policy.ts";

/** The tenant of caller `C` may create one more resource of kind `K` now. */
export interface TenantMayCreate<C, K extends ResourceKind> extends Proof<`TenantMayCreate:${K}`, [C]> {
  /** The quota slot this create holds until it is released. */
  readonly reservationId: string;
}

export class EntitlementUnavailable extends Data.TaggedError("EntitlementUnavailable")<{ readonly cause: unknown }> {}

export interface EntitlementsService {
  /** Whether the tenant's plan includes resources of this kind (billing, not quota). */
  readonly mayCreate: (tenantId: TenantId, kind: ResourceKind) => Effect.Effect<boolean, EntitlementUnavailable>;
}

/**
 * The billing hook. Injected as a Layer so the source can change without
 * touching handlers.
 *
 * TODO(cx-b4h, owner: Lawrence Chen, billing in web/services/vms/entitlements.ts):
 * replace the environment layer with the tenant's real plan. The web app's
 * `resolveVmEntitlements` needs a full Stack user with team billing metadata
 * and the web env, so it cannot be called from this Worker as is; the clean
 * source is a small read of the team's plan (Stack team server metadata or a
 * web endpoint) behind this same interface.
 */
export class Entitlements extends Context.Tag("cmux-vm/Entitlements")<Entitlements, EntitlementsService>() {}

/** Refuses every create. */
export const entitlementsDenyAllLayer = Layer.succeed(Entitlements, {
  mayCreate: () => Effect.succeed(false),
});

/**
 * Until the billing source exists: dev/test tenants (per TenantPolicy) may
 * create, everyone else is refused with 402. Fails closed in production.
 */
export const entitlementsFromPolicyLayer = Layer.effect(
  Entitlements,
  Effect.map(TenantPolicy, (policy) => ({
    mayCreate: (tenantId: TenantId) => Effect.succeed(policy.isDevTest(tenantId)),
  })),
);

export type CreateDecision<C, K extends ResourceKind> =
  | { readonly _tag: "granted"; readonly proof: TenantMayCreate<C, K> }
  | { readonly _tag: "not_entitled" }
  | { readonly _tag: "over_quota"; readonly limit: number };

/** VMs and snapshots; mesh kinds have their own budgets (src/proofs/mesh-may-create.ts). */
export const tenantMayCreate = <C, const K extends "vm" | "snapshot">(
  caller: Named<C, Principal>,
  kind: K,
): Effect.Effect<
  CreateDecision<C, K>,
  EntitlementUnavailable | StoreError | LimitsUnavailable,
  Entitlements | OwnershipStore | TenantLimits | TenantPolicy
> =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    const entitlements = yield* Entitlements;
    if (!(yield* entitlements.mayCreate(tenantId, kind))) return { _tag: "not_entitled" };
    const policy = yield* TenantPolicy;
    // Each kind has its own budget: snapshots never consume the VM limit.
    const limit = kind === "snapshot" ? policy.maxSnapshots(tenantId) : policy.maxVms(tenantId);
    const live = yield* (yield* OwnershipStore).countLive(tenantId, kind);
    const reserved = yield* (yield* TenantLimits).reserve(tenantId, kind, limit, live);
    if (!reserved.ok) return { _tag: "over_quota", limit };
    const TenantMayCreate = defineProof(`TenantMayCreate:${kind}`);
    const proof: TenantMayCreate<C, K> = Object.freeze({ ...TenantMayCreate.prove(caller), reservationId: reserved.reservationId });
    return { _tag: "granted", proof };
  });
