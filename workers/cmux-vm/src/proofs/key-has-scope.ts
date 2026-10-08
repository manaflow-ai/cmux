/**
 * Trusted module: the only place a KeyHasScope proof is minted.
 *
 * The scope is part of the proof's kind, so a proof of `vm:read` is a
 * different type from a proof of `vm:write` and cannot stand in for it.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import type { Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";

/** The credential behind caller `C` carries scope `S`. */
export interface KeyHasScope<C, S extends Scope> extends Proof<`KeyHasScope:${S}`, [C]> {}

export function keyHasScope<C, const S extends Scope>(caller: Named<C, Principal>, scope: S): KeyHasScope<C, S> | null {
  if (!caller.value.scopes.has(scope)) return null;
  const KeyHasScope = defineProof(`KeyHasScope:${scope}`);
  return KeyHasScope.prove(caller);
}
