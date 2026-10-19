import { Effect, Layer, Redacted, Schema } from "effect";
import type { Environment } from "../policy.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import { UpstreamAccessTokens, type UpstreamAccessTokensService } from "./access-tokens.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { accessTokenAllowsVm } from "../proofs/access-token-allows.ts";

const Identity = Schema.Struct({ identityId: Schema.String });
const CreatedToken = Schema.Struct({ token: Schema.String });

export function makeUpstreamAccessTokens(config: UpstreamConfig): UpstreamAccessTokensService {
  const http = makeUpstreamHttp(config);
  return {
    mintSsh: (vm, { owns, allows }, linuxUser, identityId, _expiresAt) =>
      Effect.gen(function* () {
        if (!accessTokenAllowsVm(allows, vm.value)) return yield* Effect.fail(new UpstreamError({ operation: "mintSsh.scope", status: 403 }));
        const identity = identityId === undefined
          ? yield* http.json("createIdentity", "POST", "/v5/identities", { managed: false }).pipe(
              Effect.flatMap((body) => Schema.decodeUnknown(Identity)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "createIdentity", status: null })))),
            )
          : { identityId };
        const id = encodeURIComponent(identity.identityId);
        if (identityId === undefined) {
          yield* http.json("grantIdentityVm", "POST", `/v5/identities/${id}/permissions/vm`, { vmId: upstreamIdOf(owns), allowedLinuxUsers: [linuxUser] }).pipe(
            Effect.asVoid,
            Effect.tapError(() => http.json("deleteIdentity", "DELETE", `/v5/identities/${id}`).pipe(Effect.ignore)),
          );
        }
        // Freestyle's token endpoint has no TTL field; cmux bounds use by the access-token expiry.
        const token = yield* http.json("createIdentityToken", "POST", `/v5/identities/${id}/tokens`).pipe(
          Effect.flatMap((body) => Schema.decodeUnknown(CreatedToken)(body).pipe(Effect.mapError(() => new UpstreamError({ operation: "createIdentityToken", status: null })))),
          Effect.tapError(() => http.json("deleteIdentity", "DELETE", `/v5/identities/${id}`).pipe(Effect.ignore)),
        );
        return { host: "beta-ssh.freestyle.sh", user: `${upstreamIdOf(owns)}+${linuxUser}`, password: token.token, identityId: identity.identityId, tokenId: token.token };
      }),
    revokeIdentity: (identityId) => http.json("deleteIdentity", "DELETE", `/v5/identities/${encodeURIComponent(identityId)}`).pipe(Effect.asVoid),
  };
}

export const upstreamAccessTokensLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: Environment }): Layer.Layer<UpstreamAccessTokens> =>
  Layer.succeed(UpstreamAccessTokens, makeUpstreamAccessTokens({ baseUrl: config.baseUrl, apiKey: Redacted.make(config.apiKey), environment: config.environment }));
