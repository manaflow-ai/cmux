import { Context, Data, Effect, Redacted, Schema } from "effect";
import { name, type Named } from "@gdp-ts/core";
import { compactVerify, CompactSign, importJWK, type JWK } from "jose";
import { TenantId, UserId, VmId, type TenantId as TenantIdType, type UserId as UserIdType, type VmId as VmIdType } from "../lib/ids.ts";
import type { Principal } from "../domain/principal.ts";
import { TenantLimits, type TenantLimitsService } from "../limits/service.ts";
import { mintAccessTokenAllows, type AccessTokenAllows } from "../proofs/access-token-allows.ts";

export const ACCESS_TOKEN_PREFIX = "cmux_at_";
const TOKEN_ID_PATTERN = /^at_[0-9A-HJKMNP-TV-Z]{26}$/u;

export const AccessTokenId = Schema.String.pipe(Schema.pattern(TOKEN_ID_PATTERN), Schema.brand("AccessTokenId"));
export type AccessTokenId = typeof AccessTokenId.Type;

export const ACCESS_TOKEN_SCOPES = ["exec", "pty", "files:read", "files:write", "ports", "ssh"] as const;
export const AccessTokenScope = Schema.Literal(...ACCESS_TOKEN_SCOPES);
export type AccessTokenScope = typeof AccessTokenScope.Type;

export interface AccessTokenRecord {
  readonly id: AccessTokenId;
  readonly tenantId: TenantIdType;
  readonly principal: UserIdType;
  readonly vmIds: ReadonlyArray<VmIdType>;
  readonly scopes: ReadonlyArray<AccessTokenScope>;
  readonly linuxUser: string;
  readonly expiresAt: Date;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly revokedAt: Date | null;
  readonly providerIdentityId: string | null;
}

export interface AccessTokenStoreService {
  readonly insert: (record: AccessTokenRecord) => Effect.Effect<void, AccessTokenStoreError>;
  readonly find: (tenantId: TenantIdType, id: AccessTokenId) => Effect.Effect<AccessTokenRecord | null, AccessTokenStoreError>;
  readonly list: (tenantId: TenantIdType, limit: number) => Effect.Effect<ReadonlyArray<AccessTokenRecord>, AccessTokenStoreError>;
  readonly revoke: (tenantId: TenantIdType, id: AccessTokenId, at: Date) => Effect.Effect<AccessTokenRecord | null, AccessTokenStoreError>;
  readonly setProviderIdentity: (tenantId: TenantIdType, id: AccessTokenId, identityId: string) => Effect.Effect<void, AccessTokenStoreError>;
}

export class AccessTokenStore extends Context.Tag("cmux-vm/AccessTokenStore")<AccessTokenStore, AccessTokenStoreService>() {}
export class AccessTokenStoreError extends Data.TaggedError("AccessTokenStoreError")<{ readonly operation: string; readonly cause?: unknown }> {}
export class AccessTokenRejected extends Data.TaggedError("AccessTokenRejected")<{ readonly reason: string }> {}
export class AccessTokenUnavailable extends Data.TaggedError("AccessTokenUnavailable")<{ readonly reason: string }> {}

export interface AccessTokenKeys {
  readonly kid: string;
  readonly privateJwk: JWK;
  readonly publicJwk: JWK;
  readonly active: boolean;
}

const KeyConfig = Schema.Struct({
  kid: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128)),
  privateJwk: Schema.Unknown,
  publicJwk: Schema.Unknown,
  active: Schema.Boolean,
});

export const parseAccessTokenKeys = (raw: string | undefined): ReadonlyArray<AccessTokenKeys> => {
  if (raw === undefined || raw.trim().length === 0) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    const values = Schema.decodeUnknownSync(Schema.Array(KeyConfig))(parsed);
    return values.map((value) => ({ kid: value.kid, privateJwk: value.privateJwk as JWK, publicJwk: value.publicJwk as JWK, active: value.active }));
  } catch {
    return [];
  }
};

export interface VerifiedAccessToken {
  readonly id: AccessTokenId;
  readonly tenantId: TenantIdType;
  readonly principal: UserIdType;
  readonly vmIds: ReadonlyArray<VmIdType>;
  readonly scopes: ReadonlyArray<AccessTokenScope>;
  readonly linuxUser: string;
  readonly issuedAt: Date;
  readonly expiresAt: Date;
  readonly proof: AccessTokenAllows<Principal>;
}

interface Claims {
  readonly tenant: TenantIdType;
  readonly project: null;
  readonly principal: UserIdType;
  readonly vmIds: ReadonlyArray<VmIdType>;
  readonly scopes: ReadonlyArray<AccessTokenScope>;
  readonly linuxUser: string;
  readonly iat: number;
  readonly exp: number;
  readonly jti: AccessTokenId;
}

const Claims = Schema.Struct({
  tenant: TenantId,
  project: Schema.Null,
  principal: UserId,
  vmIds: Schema.Array(VmId),
  scopes: Schema.Array(AccessTokenScope),
  linuxUser: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(64)),
  iat: Schema.Number,
  exp: Schema.Number,
  jti: AccessTokenId,
});

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

export interface AccessTokenService {
  readonly mint: (input: {
    readonly tenantId: TenantIdType;
    readonly principal: UserIdType;
    readonly vmIds: ReadonlyArray<VmIdType>;
    readonly scopes: ReadonlyArray<AccessTokenScope>;
    readonly linuxUser: string;
    readonly expiresAt: Date;
  }) => Effect.Effect<{ readonly id: AccessTokenId; readonly token: string }, AccessTokenUnavailable>;
  readonly verify: (token: Redacted.Redacted<string>, now: Date) => Effect.Effect<VerifiedAccessToken, AccessTokenRejected | AccessTokenUnavailable>;
  readonly proofFor: <C>(caller: Named<C, Principal>, record: Pick<AccessTokenRecord, "id" | "tenantId" | "vmIds" | "principal">) => AccessTokenAllows<C>;
}

export class AccessTokens extends Context.Tag("cmux-vm/AccessTokens")<AccessTokens, AccessTokenService>() {}

export const makeAccessTokenService = (keys: ReadonlyArray<AccessTokenKeys>, limits: TenantLimitsService): AccessTokenService => {
  const byKid = new Map(keys.map((key) => [key.kid, key]));
  const active = keys.find((key) => key.active);
  return {
    mint: (input) =>
      active === undefined
        ? Effect.fail(new AccessTokenUnavailable({ reason: "keys" }))
        : Effect.gen(function* () {
            const key = yield* asKey(active.privateJwk, "private-key");
            const id = newTokenId();
            const issuedAt = new Date();
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
    verify: (wrapped, now) =>
      Effect.gen(function* () {
        const raw = Redacted.value(wrapped);
        if (!raw.startsWith(ACCESS_TOKEN_PREFIX)) return yield* Effect.fail(new AccessTokenRejected({ reason: "prefix" }));
        const compact = raw.slice(ACCESS_TOKEN_PREFIX.length);
        const dot = compact.indexOf(".");
        const kid = dot <= 0 ? null : (() => {
          try {
            const header = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(compact.slice(0, dot).replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0))));
            return typeof header.kid === "string" ? header.kid : null;
          } catch {
            return null;
          }
        })();
        const config = kid === null ? undefined : byKid.get(kid);
        if (config === undefined) return yield* Effect.fail(new AccessTokenRejected({ reason: "kid" }));
        const key = yield* asKey(config.publicJwk, "public-key").pipe(Effect.mapError(() => new AccessTokenRejected({ reason: "key" })));
        const payload = yield* Effect.tryPromise({
          try: async () => {
            const result = await compactVerify(compact, key, { algorithms: ["EdDSA"] });
            return JSON.parse(new TextDecoder().decode(result.payload)) as unknown;
          },
          catch: () => new AccessTokenRejected({ reason: "signature" }),
        });
        const claims = yield* Schema.decodeUnknown(Claims)(payload).pipe(Effect.mapError(() => new AccessTokenRejected({ reason: "claims" })));
        const expiresAt = new Date(claims.exp * 1000);
        if (!Number.isFinite(expiresAt.getTime()) || claims.exp <= Math.floor(now.getTime() / 1000) || claims.iat > Math.floor(now.getTime() / 1000) + 60) {
          return yield* Effect.fail(new AccessTokenRejected({ reason: "time" }));
        }
        const revoked = yield* limits.isAccessTokenRevoked(claims.tenant, claims.jti, now.getTime()).pipe(Effect.mapError(() => new AccessTokenUnavailable({ reason: "revocation" })));
        if (revoked) return yield* Effect.fail(new AccessTokenRejected({ reason: "revoked" }));
        const principal: Principal = {
          tenantId: claims.tenant,
          actor: { kind: "access-token", tokenId: claims.jti, principal: claims.principal },
          scopes: new Set(),
          resourceAllowlist: new Set(claims.vmIds),
          credentialExpiresAt: expiresAt,
          accessTokenScopes: claims.scopes,
          accessTokenLinuxUser: claims.linuxUser,
        };
        const proof = yield* (name(principal, (caller) => Effect.succeed(mintAccessTokenAllows(caller, claims.jti, claims.tenant, claims.principal, claims.vmIds))) as unknown as Effect.Effect<AccessTokenAllows<Principal>, never>);
        return { id: claims.jti, tenantId: claims.tenant, principal: claims.principal, vmIds: claims.vmIds, scopes: claims.scopes, linuxUser: claims.linuxUser, issuedAt: new Date(claims.iat * 1000), expiresAt, proof };
      }),
    proofFor: (caller, record) => mintAccessTokenAllows(caller, record.id, record.tenantId, record.principal, record.vmIds),
  };
};
