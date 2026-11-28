/**
 * API key management (cx-b4h.12). The issuer is a key with the `admin` scope
 * or a session of a team admin (Stack `team_admin`). Rules:
 * - a new key's scopes are a subset of the issuer's (a team-admin session
 *   holds every scope, `admin` included);
 * - an issuer limited to a resource allowlist issues only keys inside it;
 * - an expiring issuer key issues only keys that expire no later than it does;
 * - the full key is returned once and only its SHA-256 hash is stored;
 * - every create and revoke is audited with the key id;
 * - another tenant's key is the same 404 as a missing one.
 */
import { HttpApiBuilder } from "@effect/platform";
import { Clock, Effect, Option, Schema } from "effect";
import { CmuxVmApi } from "../api.ts";
import { ApiKey, ApiKeyList, CreatedApiKey } from "../api/api-keys.ts";
import { InvalidRequest } from "../api/common.ts";
import { generateApiKey, hashApiKey } from "../auth/credentials.ts";
import { TeamAdmin } from "../auth/team-admin.ts";
import { ApiKeyAdminStore } from "../db/api-keys.ts";
import { actorRef, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import { Scope, SCOPES, scopeSetOf } from "../domain/scopes.ts";
import { Forbidden, NotFound, unavailable } from "../errors.ts";
import { ApiKeyId, newApiKeyId } from "../lib/ids.ts";
import type { RateClass } from "../limits/ledger.ts";
import { audited, rateLimit } from "./common.ts";

const LIST_LIMIT = 200;

const keyNotFound = () => new NotFound({ message: "API key not found" });
const notAdmin = () =>
  new Forbidden({ message: "Only an admin key or a team admin can manage API keys", missingScope: "admin" });

/**
 * Resolves what the caller may grant: the scopes of an admin key, or every
 * scope for a team admin's session. Anyone else is refused before any key is
 * read. Then applies the tenant's rate limit.
 */
const asKeyAdmin = (rateClass: RateClass) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    let grantable: ReadonlySet<Scope>;
    if (principal.scopes.has("admin")) {
      grantable = principal.scopes;
    } else if (principal.actor.kind === "session") {
      const teamAdmin = yield* TeamAdmin;
      const admin = yield* teamAdmin.isAdmin(principal.tenantId, principal.actor.userId).pipe(Effect.mapError(() => unavailable()));
      if (!admin) return yield* Effect.fail(notAdmin());
      grantable = new Set(SCOPES);
    } else {
      return yield* Effect.fail(notAdmin());
    }
    yield* rateLimit(principal, rateClass);
    return { principal, grantable };
  });

/** The first requested scope the issuer cannot grant, if any. Family scopes are compared after expansion. */
const ungrantable = (requested: ReadonlyArray<Scope>, grantable: ReadonlySet<Scope>): Scope | undefined =>
  [...scopeSetOf(requested)].find((scope) => !grantable.has(scope));

/** Whether an allowlist stays inside the issuer's: an issuer limited to some resources cannot issue an unlimited key. */
const withinAllowlist = (requested: ReadonlyArray<string> | null, issuer: Principal["resourceAllowlist"]): boolean =>
  issuer === null || (requested !== null && requested.every((id) => issuer.has(id)));

const iso = (date: Date | null) => (date === null ? null : date.toISOString());

const parseKeyId = Schema.decodeUnknownOption(ApiKeyId);
const isScope = Schema.is(Scope);

export const apiKeysHandlers = HttpApiBuilder.group(CmuxVmApi, "apiKeys", (handlers) =>
  handlers
    .handle("createApiKey", ({ payload }) =>
      Effect.gen(function* () {
        const store = yield* ApiKeyAdminStore;
        const { principal, grantable } = yield* asKeyAdmin("write");
        const scopes = [...new Set(payload.scopes)];
        const missing = ungrantable(scopes, grantable);
        if (missing !== undefined) {
          return yield* Effect.fail(new Forbidden({ message: `This credential cannot grant the ${missing} scope`, missingScope: missing }));
        }
        const allowlist = payload.resourceAllowlist === undefined ? null : [...new Set(payload.resourceAllowlist)];
        if (!withinAllowlist(allowlist, principal.resourceAllowlist)) {
          return yield* Effect.fail(new Forbidden({ message: "This credential can only issue keys inside its own resource allowlist" }));
        }
        const now = new Date(yield* Clock.currentTimeMillis);
        const expiresAt = payload.expiresAt ?? null;
        if (expiresAt !== null && expiresAt.getTime() <= now.getTime()) {
          return yield* Effect.fail(new InvalidRequest({ message: "expiresAt must be in the future" }));
        }
        // A key never outlives its issuer: otherwise a leaked short-lived key could mint a permanent one.
        const issuerExpiry = principal.credentialExpiresAt;
        if (issuerExpiry !== null && (expiresAt === null || expiresAt.getTime() > issuerExpiry.getTime())) {
          return yield* Effect.fail(
            new InvalidRequest({
              message: `This credential expires at ${issuerExpiry.toISOString()}; a key it issues must set expiresAt no later than that`,
            }),
          );
        }
        const id = newApiKeyId();
        const secret = generateApiKey();
        const keyHash = yield* hashApiKey(secret);
        return yield* audited(
          "apikey.create",
          null,
          store
            .insert({
              id,
              tenantId: principal.tenantId,
              name: payload.name,
              keyHash,
              scopes,
              resourceAllowlist: allowlist,
              createdBy: actorRef(principal.actor),
              createdAt: now,
              expiresAt,
            })
            .pipe(
              Effect.mapError(() => unavailable()),
              Effect.as(
                new CreatedApiKey({
                  id,
                  name: payload.name,
                  scopes,
                  resourceAllowlist: allowlist,
                  createdAt: now.toISOString(),
                  expiresAt: iso(expiresAt),
                  key: secret,
                }),
              ),
            ),
          (created) => created.id,
        );
      }),
    )
    .handle("listApiKeys", () =>
      Effect.gen(function* () {
        const store = yield* ApiKeyAdminStore;
        const { principal } = yield* asKeyAdmin("read");
        const keys = yield* store.list(principal.tenantId, LIST_LIMIT).pipe(Effect.mapError(() => unavailable()));
        return new ApiKeyList({
          items: keys.map(
            (key) =>
              new ApiKey({
                id: key.id,
                name: key.name,
                scopes: key.scopes.filter(isScope),
                resourceAllowlist: key.resourceAllowlist,
                createdBy: key.createdBy,
                createdAt: key.createdAt.toISOString(),
                expiresAt: iso(key.expiresAt),
                revokedAt: iso(key.revokedAt),
              }),
          ),
        });
      }),
    )
    .handle("revokeApiKey", ({ path }) =>
      Effect.gen(function* () {
        const store = yield* ApiKeyAdminStore;
        const { principal } = yield* asKeyAdmin("write");
        const parsed = parseKeyId(path.keyId);
        if (Option.isNone(parsed)) return yield* Effect.fail(keyNotFound());
        const keyId = parsed.value;
        yield* audited(
          "apikey.revoke",
          keyId,
          Effect.gen(function* () {
            const now = new Date(yield* Clock.currentTimeMillis);
            const found = yield* store.revoke(principal.tenantId, keyId, now).pipe(Effect.mapError(() => unavailable()));
            if (!found) return yield* Effect.fail(keyNotFound());
          }),
        );
      }),
    ),
);
