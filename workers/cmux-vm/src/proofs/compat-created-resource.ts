/** Proofs for provider resources that exist before their ownership row does. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import type { Principal } from "../domain/principal.ts";
import type { UpstreamId } from "../lib/ids.ts";

export type CompatCreatedKind = "vm" | "snapshot" | "identity";
export interface CompatCreatedResource<C, K extends CompatCreatedKind> extends Proof<`CompatCreatedResource:${K}`, [C]> {}

const evidence = new WeakMap<object, UpstreamId>();

const mint = <C, const K extends CompatCreatedKind>(caller: Named<C, Principal>, kind: K, upstreamId: UpstreamId): CompatCreatedResource<C, K> => {
  const proofType = defineProof(`CompatCreatedResource:${kind}`);
  const proof: CompatCreatedResource<C, K> = Object.freeze({ ...proofType.prove(caller) });
  evidence.set(proof, upstreamId);
  return proof;
};

export const mintCreatedVm = <C>(caller: Named<C, Principal>, upstreamId: UpstreamId): CompatCreatedResource<C, "vm"> => mint(caller, "vm", upstreamId);
export const mintCreatedSnapshot = <C>(caller: Named<C, Principal>, upstreamId: UpstreamId): CompatCreatedResource<C, "snapshot"> => mint(caller, "snapshot", upstreamId);
export const mintCreatedIdentity = <C>(caller: Named<C, Principal>, upstreamId: UpstreamId): CompatCreatedResource<C, "identity"> => mint(caller, "identity", upstreamId);

export const upstreamIdOfCreated = <C, K extends CompatCreatedKind>(proof: CompatCreatedResource<C, K>): UpstreamId => {
  const upstreamId = evidence.get(proof);
  if (upstreamId === undefined) throw new Error("compat created-resource proof was not minted by src/proofs");
  return upstreamId;
};
