import { defineProof, name, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";
import type { AccessTokenId } from "../access-tokens/tokens.ts";
import type { TenantId, UserId, VmId } from "../lib/ids.ts";

/** Evidence minted by the access-token verifier for the token's exact VM set. */
export interface AccessTokenAllows<_C> extends Proof<"AccessTokenAllows", [unknown]> {
  readonly tokenId: AccessTokenId;
  readonly tenantId: TenantId;
  readonly subject: UserId;
  readonly vmIds: ReadonlyArray<VmId>;
}

const AccessTokenAllowsProof = defineProof("AccessTokenAllows");

export const mintAccessTokenAllows = <C>(caller: Named<C, Principal>, tokenId: AccessTokenId, tenantId: TenantId, subject: UserId, vmIds: ReadonlyArray<VmId>): AccessTokenAllows<C> =>
  Object.freeze({ ...AccessTokenAllowsProof.prove(caller), tokenId, tenantId, subject, vmIds }) as unknown as AccessTokenAllows<C>;

/** The verifier's synchronous boundary: creates a named caller and mints the proof. */
export const accessTokenAllowsForPrincipal = (
  principal: Principal,
  tokenId: AccessTokenId,
  tenantId: TenantId,
  subject: UserId,
  vmIds: ReadonlyArray<VmId>,
) => name(principal, (caller) => Effect.succeed(mintAccessTokenAllows(caller, tokenId, tenantId, subject, vmIds)));

export const accessTokenAllowsVm = <C>(proof: AccessTokenAllows<C>, vmId: string): boolean => proof.vmIds.includes(vmId as VmId);
