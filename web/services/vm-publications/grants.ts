import * as Effect from "effect/Effect";
import { CloudVmPublicationRepository } from "./repository";
import { normalizePublicationEmail } from "./managedHostnames";
import { PublicationInputError, requireOwnedPublication, type PublicationPrincipal } from "./workflows";

export function listPublicationGrants(input: { readonly principal: PublicationPrincipal; readonly publicationId: string }) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const target = yield* requireOwnedPublication(repository, input.publicationId, input.principal.userId, input.principal.teamIds);
    return yield* repository.listEmailGrants(target.publication.id);
  });
}

export function updatePublicationGrant(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly email: string;
  readonly expiresAt?: unknown;
  readonly revoke: boolean;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const email = normalizePublicationEmail(input.email);
    if (!email) return yield* new PublicationInputError({ reason: "invalid_email", field: "email" });
    const now = input.now ?? new Date();
    if (input.expiresAt != null && typeof input.expiresAt !== "string") {
      return yield* new PublicationInputError({ reason: "invalid_expiry", field: "expiresAt" });
    }
    const expiresAt = input.expiresAt == null ? null : new Date(input.expiresAt as string);
    if (expiresAt && (!Number.isFinite(expiresAt.getTime()) || expiresAt <= now)) {
      return yield* new PublicationInputError({ reason: "invalid_expiry", field: "expiresAt" });
    }
    const repository = yield* CloudVmPublicationRepository;
    const target = yield* requireOwnedPublication(repository, input.publicationId, input.principal.userId, input.principal.teamIds);
    yield* repository.setEmailGrant({ publicationId: target.publication.id, ownerUserId: input.principal.userId, email, expiresAt, now, revoke: input.revoke });
    return { publicationId: target.publication.id, email, expiresAt: expiresAt?.toISOString() ?? null, revoked: input.revoke };
  });
}
