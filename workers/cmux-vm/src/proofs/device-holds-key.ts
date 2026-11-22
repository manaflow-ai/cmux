/**
 * Trusted module: the only place a DeviceHoldsKey proof is minted (mesh M2,
 * cx-0op.4, DESIGN.md section 5).
 *
 * DeviceHoldsKey<C, T>: for caller C acting on target T (the mesh it enrolls
 * into, or the device whose key it rotates), the install key signed this exact
 * request recently and the request was never seen before. The WireGuard key the
 * install key signed is the proof's evidence, kept in a module-private WeakMap:
 * the provider is only ever given that key (createTunnel, rotateTunnelKey), so
 * a request cannot sign one key and register another.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Clock, Effect } from "effect";
import { MeshStore } from "../db/mesh.ts";
import type { StoreError } from "../db/sql.ts";
import type { Principal } from "../domain/principal.ts";
import type { DeviceId, MeshId } from "../lib/ids.ts";
import { checkSignature, type SignedFields } from "../mesh/signed-request.ts";

const DeviceHoldsKeyProof = defineProof("DeviceHoldsKey");

export interface DeviceHoldsKey<C, T> extends Proof<"DeviceHoldsKey", [C, T]> {
  readonly purpose: SignedFields["purpose"];
}

export interface SignedKeys {
  /** The WireGuard public key the install key signed. */
  readonly wgPublicKey: string;
  readonly installPublicKey: string;
}

const evidence = new WeakMap<object, SignedKeys>();

/** The keys a DeviceHoldsKey proof was minted for. A proof not minted here has none. */
export const signedKeysOf = <C, T>(proof: DeviceHoldsKey<C, T>): SignedKeys => {
  const keys = evidence.get(proof);
  if (keys === undefined) throw new Error("DeviceHoldsKey proof was not minted by src/proofs");
  return keys;
};

export type HoldsKeyResult<C, T> =
  | { readonly _tag: "held"; readonly proof: DeviceHoldsKey<C, T> }
  /** signedAt is too far from the Worker's clock. */
  | { readonly _tag: "stale" }
  /** The signature does not verify, or the install key is not the device's. */
  | { readonly _tag: "invalid" }
  /** This exact message was accepted before. */
  | { readonly _tag: "replayed" };

/**
 * Verifies `signature` over the request's fields with `target` as the message
 * target, then claims the message (replay). `expectedInstallKey`: the device's
 * recorded install key for rotate-key; null on enroll, where the request
 * introduces it.
 */
export const deviceHoldsKey = <C, T>(
  caller: Named<C, Principal>,
  target: Named<T, MeshId | DeviceId>,
  request: Omit<SignedFields, "target">,
  signature: string,
  expectedInstallKey: string | null,
): Effect.Effect<HoldsKeyResult<C, T>, StoreError, MeshStore> =>
  Effect.gen(function* () {
    if (expectedInstallKey !== null && expectedInstallKey !== request.installPublicKey) return { _tag: "invalid" } as const;
    const now = yield* Clock.currentTimeMillis;
    const checked = yield* checkSignature({ ...request, target: target.value }, signature, now);
    if (!checked.ok) return checked.reason === "stale" ? ({ _tag: "stale" } as const) : ({ _tag: "invalid" } as const);
    const claimed = yield* (yield* MeshStore).claimSignedRequest(caller.value.tenantId, checked.messageSha256, request.purpose, checked.expiresAt, new Date(now));
    if (!claimed) return { _tag: "replayed" } as const;
    const proof: DeviceHoldsKey<C, T> = Object.freeze({ ...DeviceHoldsKeyProof.prove(caller, target), purpose: request.purpose });
    evidence.set(proof, Object.freeze({ wgPublicKey: request.wgPublicKey, installPublicKey: request.installPublicKey }));
    return { _tag: "held", proof } as const;
  });
