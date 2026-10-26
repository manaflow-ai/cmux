/**
 * Client session identities beyond create and delete (cx-b4h.6): change the
 * grant's Linux user, list, mint and revoke access tokens. Every call names an
 * identity cmux recorded for a session on exactly the proven VM, and the grant
 * it changes is the one on that VM (from the ownership proof).
 *
 * Provider token ids never leave this module: a token's public id is
 * `vct_` + the first 128 bits of SHA-256 over a fixed label, the identity id
 * and the provider token id. It is stable (nothing to store), unique per
 * identity, and names no provider id. The Linux user is always exactly one:
 * the provider's unrestricted grant (`allowedLinuxUsers: null`) is never sent.
 */
import { Effect, Schema } from "effect";
import { ClientSessionTokenId, idBodyFromDigest, type UpstreamId } from "../lib/ids.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError, type UpstreamClientService } from "./client.ts";
import type { UpstreamHttp } from "./live-http.ts";

const TokenInfos = Schema.Array(Schema.Struct({ id: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)) }));
const CreatedToken = Schema.Struct({ id: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256)), token: Schema.String.pipe(Schema.minLength(1)) });

/** The public id of one provider token of one identity. */
export const publicTokenId = (identityId: UpstreamId, upstreamTokenId: string): Effect.Effect<ClientSessionTokenId> =>
  Effect.promise(async () => {
    const material = new TextEncoder().encode(`cmux-vm-client-session-token-v1\n${identityId}\n${upstreamTokenId}`);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", material));
    return ClientSessionTokenId.make(`vct_${idBodyFromDigest(digest)}`);
  });

export const makeClientSessionTokens = (
  http: UpstreamHttp,
  apiBaseUrl: string,
  sshHost: string,
): Pick<UpstreamClientService, "setClientSessionLinuxUser" | "listClientSessionTokens" | "mintClientSessionToken" | "revokeClientSessionToken"> => {
  const malformed = (operation: string) => () => new UpstreamError({ operation, status: null });
  const base = (identityId: UpstreamId) => `/v5/identities/${encodeURIComponent(identityId)}`;

  /** The provider token ids of the identity, each with its public id. */
  const tokensOf = (identityId: UpstreamId) =>
    http.json("listAccessTokens", "GET", `${base(identityId)}/tokens`).pipe(
      Effect.flatMap((body) => Schema.decodeUnknown(TokenInfos)(body).pipe(Effect.mapError(malformed("listAccessTokens")))),
      Effect.flatMap((infos) => Effect.forEach(infos, (info) => Effect.map(publicTokenId(identityId, info.id), (id) => ({ id, upstream: info.id })))),
    );

  return {
    setClientSessionLinuxUser: (_vm, { owns }, identityId, linuxUser) =>
      http
        .json("updateVmAllowedLinuxUsers", "PATCH", `${base(identityId)}/permissions/vm/${encodeURIComponent(upstreamIdOf(owns))}`, {
          allowedLinuxUsers: [linuxUser],
        })
        .pipe(Effect.asVoid),
    listClientSessionTokens: (_vm, _proofs, identityId) => Effect.map(tokensOf(identityId), (tokens) => tokens.map((token) => token.id)),
    mintClientSessionToken: (_vm, { owns }, identityId) =>
      http.json("createAccessToken", "POST", `${base(identityId)}/tokens`).pipe(
        Effect.flatMap((body) => Schema.decodeUnknown(CreatedToken)(body).pipe(Effect.mapError(malformed("createAccessToken")))),
        Effect.flatMap((created) =>
          Effect.map(publicTokenId(identityId, created.id), (tokenId) => ({
            tokenId,
            token: created.token,
            providerVmId: upstreamIdOf(owns),
            apiBaseUrl,
            sshHost,
          })),
        ),
      ),
    revokeClientSessionToken: (_vm, _proofs, identityId, tokenId) =>
      Effect.gen(function* () {
        const match = (yield* tokensOf(identityId)).find((token) => token.id === tokenId);
        if (match === undefined) return "gone" as const;
        return yield* http.json("revokeAccessToken", "DELETE", `${base(identityId)}/tokens/${encodeURIComponent(match.upstream)}`).pipe(
          Effect.as("revoked" as const),
          Effect.catchAll((error) => (error.status === 404 ? Effect.succeed("gone" as const) : Effect.fail(error))),
        );
      }),
  };
};
