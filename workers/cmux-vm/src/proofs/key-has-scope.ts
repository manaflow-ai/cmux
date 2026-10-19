/**
 * Trusted module: the only place a KeyHasScope proof is minted.
 *
 * The scope is part of the proof's kind, so a proof of `vm:read` is a
 * different type from a proof of `vm:write` and cannot stand in for it.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import type { Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import type { AccessTokenAllows } from "./access-token-allows.ts";

/** The credential behind caller `C` carries scope `S`. */
export interface KeyHasScope<C, S extends Scope> extends Proof<`KeyHasScope:${S}`, [C]> {
  readonly linuxUser: string;
  readonly restrictLinuxUser: boolean;
}

export function keyHasScope<C, const S extends Scope>(caller: Named<C, Principal>, scope: S, allows?: AccessTokenAllows<C>): KeyHasScope<C, S> | null {
  if (!caller.value.scopes.has(scope)) return null;
  if (caller.value.actor.kind === "access-token" && allows === undefined) return null;
  const KeyHasScope = defineProof(`KeyHasScope:${scope}`);
  return Object.freeze({ ...KeyHasScope.prove(caller), linuxUser: allows?.linuxUser ?? "root", restrictLinuxUser: allows !== undefined });
}
