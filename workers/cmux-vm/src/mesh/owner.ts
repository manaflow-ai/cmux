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

/** A policy publication requires fresh membership; expired/revoked keys never own live access. */
export const ownerStillValid = (tenantId: Principal["tenantId"], actor: Principal["actor"], fresh = false) => Effect.gen(function* () {
  if (actor.kind === "session") return yield* (yield* TeamMembership).isMember(tenantId, actor.userId, { fresh }).pipe(Effect.mapError(() => unavailable()));
  if (actor.kind === "service") return false;
  const key = yield* (yield* ApiKeyStore).findActiveById(tenantId, actor.keyId, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => unavailable()));
  return Option.isSome(key);
});
