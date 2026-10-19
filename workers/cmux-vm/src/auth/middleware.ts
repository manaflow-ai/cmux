/**
 * Authentication only: turns the bearer credential into a Principal. It makes
 * no decision about any resource; handlers prove scope and ownership with the
 * gdp-ts proofs in src/proofs/ right where the result is needed.
 */
import { HttpServerRequest } from "@effect/platform";
import { name } from "@gdp-ts/core";
import { Clock, Effect, Layer, Option, Redacted } from "effect";
import { Authentication } from "../api.ts";
import { ACCESS_TOKEN_PREFIX, AccessTokens } from "../access-tokens/tokens.ts";
import { ApiKeyStore } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import { SESSION_SCOPES, scopeSetOf } from "../domain/scopes.ts";
import { Forbidden, type ServiceUnavailable, Unauthorized, unavailable } from "../errors.ts";
import { verifierAccessTokenProof } from "../proofs/access-token-allows.ts";
import { serviceMayActFor, servicePrincipal } from "../proofs/service-may-act-for.ts";
import { ServiceKeys, type ServiceKey } from "./service-keys.ts";
import {
  API_KEY_PREFIX,
  decodeTenantId,
  hashApiKey,
  isApiKeyShaped,
  SessionVerifier,
  TeamMembership,
} from "./credentials.ts";

export const TEAM_HEADER = "x-cmux-team-id";

const unauthorized = (message = "A valid cmux VM API key or session token is required") => new Unauthorized({ message });

export const authenticationLayer = Layer.effect(
  Authentication,
  Effect.gen(function* () {
    const sessions = yield* SessionVerifier;
    const membership = yield* TeamMembership;
    const apiKeys = yield* ApiKeyStore;
    const serviceKeys = yield* ServiceKeys;
    const accessTokens = yield* Effect.serviceOption(AccessTokens);

    /** A service key acts only for the team its request names, and only when its team list allows that team. */
    const fromServiceKey = (
      key: ServiceKey,
    ): Effect.Effect<Principal, Unauthorized | Forbidden, HttpServerRequest.HttpServerRequest> =>
      Effect.gen(function* () {
        const request = yield* HttpServerRequest.HttpServerRequest;
        const tenant = decodeTenantId(request.headers[TEAM_HEADER]);
        if (Option.isNone(tenant)) return yield* Effect.fail(unauthorized("Service keys must name a team in the X-Cmux-Team-Id header"));
        return yield* name(key, tenant.value, (service, team) => {
          const proof = serviceMayActFor(service, team);
          return proof === null
            ? Effect.fail(new Forbidden({ message: "This service key may not act for this team" }))
            : Effect.succeed(servicePrincipal(service, team, proof));
        });
      });

    const fromApiKey = (
      key: string,
    ): Effect.Effect<Principal, Unauthorized | Forbidden | ServiceUnavailable, HttpServerRequest.HttpServerRequest> =>
      Effect.gen(function* () {
        if (!isApiKeyShaped(key)) return yield* Effect.fail(unauthorized());
        const now = new Date(yield* Clock.currentTimeMillis);
        const hash = yield* hashApiKey(key);
        const service = yield* serviceKeys.find(hash);
        if (Option.isSome(service)) return yield* fromServiceKey(service.value);
        const record = yield* apiKeys.findActiveByHash(hash, now).pipe(
          Effect.tapError((error) => Effect.logWarning("cmux-vm dependency unavailable").pipe(Effect.annotateLogs({ operation: error.operation }))),
          Effect.mapError(() => unavailable()),
        );
        if (Option.isNone(record)) return yield* Effect.fail(unauthorized());
        const principal = {
          tenantId: record.value.tenantId,
          actor: { kind: "api_key", keyId: record.value.id },
          scopes: scopeSetOf(record.value.scopes),
          resourceAllowlist: record.value.resourceAllowlist === null ? null : new Set(record.value.resourceAllowlist),
          credentialExpiresAt: record.value.expiresAt,
        };
        return principal;
      });

    const fromSession = (
      token: Redacted.Redacted<string>,
    ): Effect.Effect<Principal, Unauthorized | Forbidden | ServiceUnavailable, HttpServerRequest.HttpServerRequest> =>
      Effect.gen(function* () {
        const request = yield* HttpServerRequest.HttpServerRequest;
        const tenant = decodeTenantId(request.headers[TEAM_HEADER]);
        if (Option.isNone(tenant)) return yield* Effect.fail(unauthorized("Session tokens must name a team in the X-Cmux-Team-Id header"));
        const now = new Date(yield* Clock.currentTimeMillis);
        const userId = yield* sessions.verify(token, now).pipe(
          Effect.catchTags({
            SessionRejected: () => Effect.fail(unauthorized()),
            IdentityUnavailable: (error) =>
              Effect.logWarning("cmux-vm dependency unavailable").pipe(
                Effect.annotateLogs({ operation: `stack.${error.reason}` }),
                Effect.zipRight(Effect.fail(unavailable())),
              ),
          }),
        );
        const member = yield* membership.isMember(tenant.value, userId).pipe(
          Effect.tapError((error) => Effect.logWarning("cmux-vm dependency unavailable").pipe(Effect.annotateLogs({ operation: `stack.${error.reason}` }))),
          Effect.mapError(() => unavailable()),
        );
        if (!member) return yield* Effect.fail(new Forbidden({ message: "You are not a member of this team" }));
        const principal: Principal = {
          tenantId: tenant.value,
          actor: { kind: "session", userId },
          scopes: SESSION_SCOPES,
          resourceAllowlist: null,
          credentialExpiresAt: null,
        };
        return principal;
      });

    const fromAccessToken = (token: string): Effect.Effect<Principal, Unauthorized | ServiceUnavailable> => {
      const now = new Date(Date.now());
      if (Option.isNone(accessTokens)) return Effect.fail(unavailable());
      return Effect.gen(function* () {
        const verified = yield* accessTokens.value.verify(Redacted.make(token), now);
        const principal: Principal = {
          tenantId: verified.tenantId,
          actor: { kind: "access-token", tokenId: verified.id, principal: verified.principal },
          scopes: scopeSetOf([
            ...(verified.scopes.includes("exec") ? ["vm:exec" as const] : []),
            ...(verified.scopes.includes("pty") ? ["vm:terminal" as const] : []),
            ...(verified.scopes.includes("files:read") || verified.scopes.includes("files:write") ? ["vm:files" as const] : []),
          ]),
          resourceAllowlist: new Set(verified.vmIds),
          credentialExpiresAt: verified.expiresAt,
        };
        const proof = yield* verifierAccessTokenProof(principal, verified.id, verified.tenantId, verified.principal, verified.vmIds, verified.scopes, verified.linuxUser);
        return Object.assign(principal, { accessTokenProof: proof });
      }).pipe(
        Effect.catchTags({
          AccessTokenRejected: () => Effect.fail(unauthorized()),
          AccessTokenUnavailable: () => Effect.fail(unavailable()),
        }),
      );
    };

    return Authentication.of({
      bearer: (token) => {
        const raw = Redacted.value(token);
        if (raw.length === 0) return Effect.fail(unauthorized());
        if (raw.startsWith(ACCESS_TOKEN_PREFIX)) return fromAccessToken(raw);
        return raw.startsWith(API_KEY_PREFIX) ? fromApiKey(raw) : fromSession(token);
      },
    });
  }),
);
