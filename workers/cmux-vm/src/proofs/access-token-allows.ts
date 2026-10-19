import { defineProof, name, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Redacted, Schema } from "effect";
import { compactVerify, importJWK } from "jose";
import type { Principal } from "../domain/principal.ts";
import { ACCESS_TOKEN_PREFIX, AccessTokenRejected, AccessTokenUnavailable, Claims, type AccessTokenId, type AccessTokenKeys, type VerifiedAccessToken } from "../access-tokens/tokens.ts";
import type { TenantLimitsService } from "../limits/service.ts";
import { scopeSetOf } from "../domain/scopes.ts";
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

export interface AccessTokenEvidence {
  readonly withCaller: <A>(use: <C>(caller: Named<C, Principal>, proof: AccessTokenAllows<C>) => A) => A;
}

const AccessTokenAllowsProof = defineProof("AccessTokenAllows");

const mintAccessTokenAllows = <C>(caller: Named<C, Principal>, tokenId: AccessTokenId, tenantId: TenantId, subject: UserId, vmIds: ReadonlyArray<VmId>, scopes: ReadonlyArray<string>, linuxUser: string): AccessTokenAllows<C> =>
  Object.freeze({ ...AccessTokenAllowsProof.prove(caller), tokenId, tenantId, subject, vmIds, scopes, linuxUser });

const verifierAccessTokenProof = (
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
      withCaller: <A>(use: <C>(caller: Named<C, Principal>, proof: AccessTokenAllows<C>) => A): A => use(caller, proof),
    });
  }));

export const accessTokenAllowsVm = <C>(proof: AccessTokenAllows<C>, vmId: VmId): boolean => proof.vmIds.includes(vmId);

export const verifyAccessToken = (
  wrapped: Redacted.Redacted<string>,
  now: Date,
  keys: ReadonlyArray<AccessTokenKeys>,
  limits: TenantLimitsService,
): Effect.Effect<VerifiedAccessToken, AccessTokenRejected | AccessTokenUnavailable> =>
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
        const config = kid === null ? undefined : keys.find((entry) => entry.kid === kid);
        if (config === undefined) return yield* Effect.fail(new AccessTokenRejected({ reason: "kid" }));
        const key = yield* Effect.tryPromise({ try: () => importJWK(config.publicJwk, "EdDSA"), catch: () => new AccessTokenRejected({ reason: "key" }) });
        const payload = yield* Effect.tryPromise({
          try: async () => {
            const result = await compactVerify(compact, key, { algorithms: ["EdDSA"] });
            return JSON.parse(new TextDecoder().decode(result.payload));
          },
          catch: () => new AccessTokenRejected({ reason: "signature" }),
        });
        const claims = yield* Schema.decodeUnknown(Claims)(payload).pipe(Effect.mapError(() => new AccessTokenRejected({ reason: "claims" })));
        const expiresAt = new Date(claims.exp * 1000);
        if (!Number.isFinite(expiresAt.getTime()) || claims.exp <= Math.floor(now.getTime() / 1000) || claims.iat > Math.floor(now.getTime() / 1000) + 60 || claims.exp - claims.iat > 86400) {
          return yield* Effect.fail(new AccessTokenRejected({ reason: "time" }));
        }
        const revoked = yield* limits.isAccessTokenRevoked(claims.tenant, claims.jti, now.getTime()).pipe(Effect.mapError(() => new AccessTokenUnavailable({ reason: "revocation" })));
        if (revoked) return yield* Effect.fail(new AccessTokenRejected({ reason: "revoked" }));
        const principal: Principal = {
          tenantId: claims.tenant,
          actor: { kind: "access-token", tokenId: claims.jti, principal: claims.principal },
          scopes: scopeSetOf([
            ...(claims.scopes.includes("exec") ? ["vm:exec"] : []),
            ...(claims.scopes.includes("pty") ? ["vm:terminal"] : []),
            ...(claims.scopes.includes("files:read") || claims.scopes.includes("files:write") ? ["vm:files"] : []),
          ]),
          resourceAllowlist: new Set(claims.vmIds),
          credentialExpiresAt: expiresAt,
        };
        const proof = yield* verifierAccessTokenProof(principal, claims.jti, claims.tenant, claims.principal, claims.vmIds, claims.scopes, claims.linuxUser);
        return { id: claims.jti, tenantId: claims.tenant, principal: claims.principal, vmIds: claims.vmIds, scopes: claims.scopes, linuxUser: claims.linuxUser, issuedAt: new Date(claims.iat * 1000), expiresAt, proof, authenticatedPrincipal: Object.assign(principal, { accessTokenProof: proof }) };
      });
