import { Clock, Effect } from "effect";
import { CompactSign, importJWK, type JWK } from "jose";
import { ACCESS_TOKEN_PREFIX, AccessTokenId, AccessTokenUnavailable, type AccessTokenKeys, type AccessTokenService, type Claims } from "./tokens.ts";
import type { TenantLimitsService } from "../limits/service.ts";
import { verifyAccessToken } from "../proofs/access-token-allows.ts";

const base32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const newTokenId = (): AccessTokenId => {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let bits = 0;
  let value = 0;
  let text = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5 && text.length < 26) {
      text += base32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  while (text.length < 26) text += "0";
  return AccessTokenId.make(`at_${text}`);
};

type ImportedKey = Awaited<ReturnType<typeof importJWK>>;
const asKey = (jwk: JWK, operation: string): Effect.Effect<ImportedKey, AccessTokenUnavailable> =>
  Effect.tryPromise({ try: () => importJWK(jwk, "EdDSA"), catch: () => new AccessTokenUnavailable({ reason: operation }) });


export const makeAccessTokenService = (keys: ReadonlyArray<AccessTokenKeys>, limits: TenantLimitsService): AccessTokenService => {
  const active = keys.find((key) => key.active);
  return {
    mint: (input) =>
      active === undefined
        ? Effect.fail(new AccessTokenUnavailable({ reason: "keys" }))
        : Effect.gen(function* () {
            const key = yield* asKey(active.privateJwk, "private-key");
            const id = newTokenId();
            const issuedAt = new Date(yield* Clock.currentTimeMillis);
            const claims: Claims = {
              tenant: input.tenantId,
              project: null,
              principal: input.principal,
              vmIds: input.vmIds,
              scopes: input.scopes,
              linuxUser: input.linuxUser,
              iat: Math.floor(issuedAt.getTime() / 1000),
              exp: Math.floor(input.expiresAt.getTime() / 1000),
              jti: id,
            };
            const token = yield* Effect.tryPromise({
              try: () => new CompactSign(new TextEncoder().encode(JSON.stringify(claims))).setProtectedHeader({ alg: "EdDSA", kid: active.kid, typ: "JWT" }).sign(key),
              catch: () => new AccessTokenUnavailable({ reason: "sign" }),
            });
            return { id, token: `${ACCESS_TOKEN_PREFIX}${token}` };
          }),
    verify: (wrapped, now) => verifyAccessToken(wrapped, now, keys, limits),
  };
};
