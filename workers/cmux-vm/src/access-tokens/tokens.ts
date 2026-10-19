import { Context, Data, Effect, Redacted, Schema } from "effect";
import type { JWK } from "jose";
import { TenantId, UserId, VmId, type TenantId as TenantIdType, type UserId as UserIdType, type VmId as VmIdType } from "../lib/ids.ts";
import type { Principal } from "../domain/principal.ts";
import type { AccessTokenEvidence } from "../proofs/access-token-allows.ts";

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
  readonly listProviderIdentities: (now: Date) => Effect.Effect<ReadonlyArray<AccessTokenRecord>, AccessTokenStoreError>;
  readonly clearProviderIdentity: (tenantId: TenantIdType, id: AccessTokenId, identityId: string) => Effect.Effect<void, AccessTokenStoreError>;
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

const isJwk = (value: unknown): value is JWK =>
  typeof value === "object" && value !== null && "kty" in value && value.kty === "OKP" &&
  "crv" in value && value.crv === "Ed25519" && "x" in value && typeof value.x === "string" && /^[A-Za-z0-9_-]{43}$/u.test(value.x);

export const parseAccessTokenKeys = (raw: string | undefined): ReadonlyArray<AccessTokenKeys> => {
  if (raw === undefined || raw.trim().length === 0) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    const values = Schema.decodeUnknownSync(Schema.Array(KeyConfig))(parsed);
    const kids = new Set<string>();
    const keys = values.flatMap((value) => {
      if (!isJwk(value.privateJwk) || !isJwk(value.publicJwk) || kids.has(value.kid) ||
        typeof value.privateJwk.d !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(value.privateJwk.d) ||
        value.publicJwk.d !== undefined || value.privateJwk.x !== value.publicJwk.x) return [];
      kids.add(value.kid);
      return [{ kid: value.kid, privateJwk: value.privateJwk, publicJwk: value.publicJwk, active: value.active }];
    });
    if (keys.length !== values.length || keys.filter((key) => key.active).length > 1) {
      console.error(JSON.stringify({ event: "cmux_vm_access_token_keys_invalid", reason: "duplicate_or_invalid_kid" }));
      return [];
    }
    return keys;
  } catch {
    console.error(JSON.stringify({ event: "cmux_vm_access_token_keys_invalid", reason: "parse" }));
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
  readonly proof: AccessTokenEvidence;
  readonly authenticatedPrincipal: Principal;
}

export interface Claims {
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

export const Claims = Schema.Struct({
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
}

export class AccessTokens extends Context.Tag("cmux-vm/AccessTokens")<AccessTokens, AccessTokenService>() {}
