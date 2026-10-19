import { defineProof, name, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";
import type { AccessTokenId } from "../access-tokens/tokens.ts";
import type { TenantId, UserId, VmId } from "../lib/ids.ts";

interface AccessTokenClaims {
  readonly tokenId: AccessTokenId;
  readonly tenantId: TenantId;
  readonly subject: UserId;
  readonly vmIds: ReadonlyArray<VmId>;
  readonly scopes: ReadonlyArray<string>;
  readonly linuxUser: string;
}

/** Evidence minted by the access-token verifier for the token's exact VM set. */
export interface AccessTokenAllows<C> extends Proof<"AccessTokenAllows", [C]>, AccessTokenClaims {}

export interface AccessTokenEvidence extends AccessTokenClaims {
  readonly withCaller: <A>(use: <C>(caller: Named<C, Principal>, proof: AccessTokenAllows<C>) => A) => A;
}

const AccessTokenAllowsProof = defineProof("AccessTokenAllows");

const mintAccessTokenAllows = <C>(caller: Named<C, Principal>, tokenId: AccessTokenId, tenantId: TenantId, subject: UserId, vmIds: ReadonlyArray<VmId>, scopes: ReadonlyArray<string>, linuxUser: string): AccessTokenAllows<C> =>
  Object.freeze({ ...AccessTokenAllowsProof.prove(caller), tokenId, tenantId, subject, vmIds, scopes, linuxUser });

export const verifierAccessTokenProof = (
  principal: Principal,
  tokenId: AccessTokenId,
  tenantId: TenantId,
  subject: UserId,
  vmIds: ReadonlyArray<VmId>,
  scopes: ReadonlyArray<string>,
  linuxUser: string,
): Effect.Effect<AccessTokenEvidence> =>
  Effect.sync(() => name(principal, (caller): AccessTokenEvidence => {
    const proof = mintAccessTokenAllows(caller, tokenId, tenantId, subject, vmIds, scopes, linuxUser);
    return Object.freeze({
      tokenId,
      tenantId,
      subject,
      vmIds,
      scopes,
      linuxUser,
      withCaller: <A>(use: <C>(caller: Named<C, Principal>, proof: AccessTokenAllows<C>) => A): A => use(caller, proof),
    });
  }));

export const accessTokenAllowsVm = <C>(proof: AccessTokenAllows<C>, vmId: VmId): boolean => proof.vmIds.includes(vmId);
