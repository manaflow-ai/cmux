import { Clock, Effect, Option, Schema } from "effect";
import { TeamMembership } from "../auth/credentials.ts";
import { ApiKeyStore } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import { unavailable } from "../errors.ts";
import { ApiKeyId, UserId } from "../lib/ids.ts";

export const actorOf = (createdBy: string): Option.Option<Principal["actor"]> => {
  const [kind, ...rest] = createdBy.split(":");
  const id = rest.join(":");
  if (kind === "user") return Option.map(Schema.decodeUnknownOption(UserId)(id), (userId) => ({ kind: "session" as const, userId }));
  if (kind === "key") return Option.map(Schema.decodeUnknownOption(ApiKeyId)(id), (keyId) => ({ kind: "api_key" as const, keyId }));
  return Option.none();
};

/** A live owner and its known expiry; None refuses, Some(null) has no known deadline. */
export const ownerLease = (tenantId: Principal["tenantId"], actor: Principal["actor"], fresh = false) => Effect.gen(function* () {
  if (actor.kind === "session") {
    const active = yield* (yield* TeamMembership).isMember(tenantId, actor.userId, { fresh }).pipe(Effect.mapError(() => unavailable()));
    return active ? Option.some<number | null>(null) : Option.none<number | null>();
  }
  if (actor.kind === "service") return Option.none<number | null>();
  const key = yield* (yield* ApiKeyStore).findActiveById(tenantId, actor.keyId, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => unavailable()));
  return Option.map(key, (held) => held.expiresAt === null ? null : held.expiresAt.getTime());
});

/** A policy publication requires fresh membership; expired/revoked keys never own live access. */
export const ownerStillValid = (tenantId: Principal["tenantId"], actor: Principal["actor"], fresh = false) =>
  ownerLease(tenantId, actor, fresh).pipe(Effect.map(Option.isSome));
