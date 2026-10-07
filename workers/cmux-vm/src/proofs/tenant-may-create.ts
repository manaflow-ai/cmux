/**
 * Trusted module: the only place a TenantMayCreate proof is minted.
 *
 * Creation is gated by entitlement (billing and quota). The resource kind is
 * part of the proof's kind, so a VM proof cannot authorize a snapshot.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Context, Data, Effect, Layer } from "effect";
import type { Principal } from "../domain/principal.ts";
import type { ResourceKind, TenantId } from "../lib/ids.ts";

/** The tenant of caller `C` may create one more resource of kind `K` now. */
export interface TenantMayCreate<C, K extends ResourceKind> extends Proof<`TenantMayCreate:${K}`, [C]> {}

export class EntitlementUnavailable extends Data.TaggedError("EntitlementUnavailable")<{ readonly cause: unknown }> {}

export interface EntitlementsService {
  /** Whether the tenant's plan and quota allow one more resource of this kind. */
  readonly mayCreate: (tenantId: TenantId, kind: ResourceKind) => Effect.Effect<boolean, EntitlementUnavailable>;
}

export class Entitlements extends Context.Tag("cmux-vm/Entitlements")<Entitlements, EntitlementsService>() {}

/**
 * No create endpoint exists yet, and the billing and quota hooks arrive with
 * the first one. Until then every create is refused.
 */
export const entitlementsDenyAllLayer = Layer.succeed(Entitlements, {
  mayCreate: () => Effect.succeed(false),
});

export const tenantMayCreate = <C, const K extends ResourceKind>(
  caller: Named<C, Principal>,
  kind: K,
): Effect.Effect<TenantMayCreate<C, K> | null, EntitlementUnavailable, Entitlements> =>
  Effect.gen(function* () {
    const entitlements = yield* Entitlements;
    if (!(yield* entitlements.mayCreate(caller.value.tenantId, kind))) return null;
    const TenantMayCreate = defineProof(`TenantMayCreate:${kind}`);
    const proof: TenantMayCreate<C, K> = TenantMayCreate.prove(caller);
    return proof;
  });
