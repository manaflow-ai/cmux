import { defineProof, name, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";
import type { AccessTokenId } from "../access-tokens/tokens.ts";
import type { TenantId, UserId, VmId } from "../lib/ids.ts";

/** Evidence minted by the access-token verifier for the token's exact VM set. */
export interface AccessTokenAllows<C> extends Proof<"AccessTokenAllows", [C]> {
  readonly tokenId: AccessTokenId;
  readonly tenantId: TenantId;
  readonly subject: UserId;
  readonly vmIds: ReadonlyArray<VmId>;
  readonly scopes: ReadonlyArray<string>;
  readonly linuxUser: string;
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
): Effect.Effect<AccessTokenAllows<Principal>> =>
  name(principal, (caller) => Effect.succeed(mintAccessTokenAllows(caller, tokenId, tenantId, subject, vmIds, scopes, linuxUser))) as unknown as Effect.Effect<AccessTokenAllows<Principal>>;

export const accessTokenAllowsVm = <C>(proof: AccessTokenAllows<C>, vmId: string): boolean => proof.vmIds.includes(vmId as VmId);
