import { Context, Effect } from "effect";
import type { Named } from "@gdp-ts/core";
import type { VmId } from "../lib/ids.ts";
import type { Principal } from "../domain/principal.ts";
import type { AccessTokenAllows } from "../proofs/access-token-allows.ts";
import type { TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import type { UpstreamError } from "./client.ts";

export interface DelegatedSsh {
  readonly host: string;
  readonly user: string;
  readonly password: string;
  readonly identityId: string;
  readonly tokenId: string;
}

export interface UpstreamAccessTokensService {
  readonly mintSsh: <C, V>(
    vm: Named<V, VmId>,
    proofs: { readonly owns: TenantOwnsResource<C, V>; readonly allows: AccessTokenAllows<Principal> },
    linuxUser: string,
    identityId?: string,
    _expiresAt?: Date,
  ) => Effect.Effect<DelegatedSsh, UpstreamError>;
  readonly revokeIdentity: (identityId: string) => Effect.Effect<void, UpstreamError>;
}

export class UpstreamAccessTokens extends Context.Tag("cmux-vm/UpstreamAccessTokens")<UpstreamAccessTokens, UpstreamAccessTokensService>() {}
