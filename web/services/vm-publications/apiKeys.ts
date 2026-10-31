import * as Effect from "effect/Effect";
import {
  CloudVmPublicationRepository,
  PublicationConflictError,
  PublicationNotFoundError,
  type CloudVmPublicationApiKeyRow,
} from "./repository";
import {
  PUBLICATION_API_KEY_COOKIE,
  hashPublicationToken,
  randomPublicationApiKey,
} from "./security";
import {
  PublicationInputError,
  createPublication,
  ensurePublicationForwardAuth,
  requireOwnedPublication,
  type PublicationDto,
  type PublicationForwardAuthConfig,
  type PublicationPrincipal,
} from "./workflows";

export const DEFAULT_API_KEY_NAME = "API key";
const MAX_API_KEY_NAME_LENGTH = 64;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

/** What a list shows: never the key or its hash. */
export type PublicationApiKeyDto = {
  readonly id: string;
  readonly publicationId: string;
  readonly name: string;
  /** The key's last four characters. */
  readonly hint: string;
  readonly createdAt: string;
  readonly expiresAt: string | null;
  readonly revokedAt: string | null;
};

/** A newly minted key. `token` is answered this one time and never stored. */
export type MintedPublicationApiKey = {
  readonly apiKey: PublicationApiKeyDto;
  readonly token: string;
  /** API clients send the key as this cookie; the VM never receives it. */
  readonly cookieName: typeof PUBLICATION_API_KEY_COOKIE;
  readonly cookie: string;
};

export type ProvisionedApi = MintedPublicationApiKey & {
  readonly publication: PublicationDto;
  readonly url: string;
};

export function apiKeyDto(row: CloudVmPublicationApiKeyRow): PublicationApiKeyDto {
  return {
    id: row.id,
    publicationId: row.publicationId,
    name: row.name,
    hint: row.tokenHint,
    createdAt: row.createdAt.toISOString(),
    expiresAt: row.expiresAt?.toISOString() ?? null,
    revokedAt: row.revokedAt?.toISOString() ?? null,
  };
}

/** One printable line, no control characters, at most 64 characters. */
export function normalizeApiKeyName(value: unknown): string | null {
  if (value == null) return DEFAULT_API_KEY_NAME;
  if (typeof value !== "string") return null;
  const name = value.trim();
  // eslint-disable-next-line no-control-regex
  if (!name || name.length > MAX_API_KEY_NAME_LENGTH || /[\u0000-\u001f\u007f]/u.test(name)) return null;
  return name;
}

/** An optional ISO time in the future; anything else is an input error. */
export function apiKeyExpiry(value: unknown, now: Date) {
  if (value == null) return Effect.succeed(null);
  const expiresAt = typeof value === "string" ? new Date(value) : null;
  return expiresAt && Number.isFinite(expiresAt.getTime()) && expiresAt > now
    ? Effect.succeed(expiresAt)
    : Effect.fail(new PublicationInputError({ reason: "invalid_expiry", field: "expiresAt" }));
}

export function listPublicationApiKeys(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const repository = yield* CloudVmPublicationRepository;
    const target = yield* requireOwnedPublication(repository, input.publicationId, input.principal.userId, input.principal.teamIds);
    const keys = yield* repository.listApiKeys({ publicationId: target.publication.id, now: input.now ?? new Date() });
    return keys.map(apiKeyDto);
  });
}

/**
 * Mint a key for a protected publication the caller owns. The shared
 * forward-auth config is brought current first, so the cookie the key rides in
 * is withheld from the VM before the key exists.
 */
export function createPublicationApiKey(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly name?: unknown;
  readonly expiresAt?: unknown;
  readonly forwardAuth?: PublicationForwardAuthConfig;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const now = input.now ?? new Date();
    const name = normalizeApiKeyName(input.name);
    if (!name) return yield* new PublicationInputError({ reason: "invalid_api_key_name", field: "name" });
    const expiresAt = yield* apiKeyExpiry(input.expiresAt, now);
    const repository = yield* CloudVmPublicationRepository;
    const target = yield* requireOwnedPublication(repository, input.publicationId, input.principal.userId, input.principal.teamIds);
    if (target.publication.accessMode === "public") {
      return yield* new PublicationConflictError({ reason: "publication_public" });
    }
    if (target.publication.state !== "active") {
      return yield* new PublicationConflictError({ reason: "publication_not_active" });
    }
    yield* ensurePublicationForwardAuth({ forwardAuth: input.forwardAuth, now });
    const token = randomPublicationApiKey();
    const row = yield* repository.createApiKey({
      publicationId: target.publication.id,
      ownerUserId: input.principal.userId,
      name,
      tokenHash: hashPublicationToken(token),
      tokenHint: token.slice(-4),
      expiresAt,
      now,
    });
    return mintedKey(row, token);
  });
}

/** Revocation takes effect on the next request: the edge asks CMUX every time. */
export function revokePublicationApiKey(input: {
  readonly principal: PublicationPrincipal;
  readonly publicationId: string;
  readonly keyId: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const keyId = input.keyId.trim();
    // Key ids are UUIDs; anything else names no key and must not reach a uuid column.
    if (!UUID_PATTERN.test(keyId)) return yield* new PublicationNotFoundError({ resource: "api_key" });
    const repository = yield* CloudVmPublicationRepository;
    const target = yield* requireOwnedPublication(repository, input.publicationId, input.principal.userId, input.principal.teamIds);
    const row = yield* repository.revokeApiKey({
      publicationId: target.publication.id,
      ownerUserId: input.principal.userId,
      keyId,
      now: input.now ?? new Date(),
    });
    return apiKeyDto(row);
  });
}

/**
 * One call from a port on a Cloud VM to a working, access-controlled API URL:
 * publish the port under a generated hostname (or reuse the live publication
 * of that port), then mint an API key for it. Public access is refused, since
 * a key would guard nothing.
 */
export function provisionPublicationApi(input: {
  readonly principal: PublicationPrincipal;
  readonly providerVmId: string;
  readonly port: number;
  readonly accessMode?: "personal" | "team";
  readonly teamId?: string | null;
  readonly name?: unknown;
  readonly expiresAt?: unknown;
  readonly forwardAuth?: PublicationForwardAuthConfig;
  readonly generatedDomain?: string;
  readonly now?: Date;
}) {
  return Effect.gen(function* () {
    const now = input.now ?? new Date();
    // Validate key input before anything is published.
    if (!normalizeApiKeyName(input.name)) {
      return yield* new PublicationInputError({ reason: "invalid_api_key_name", field: "name" });
    }
    yield* apiKeyExpiry(input.expiresAt, now);
    if ((input.accessMode as string | undefined) === "public") {
      return yield* new PublicationInputError({ reason: "invalid_access_mode", field: "accessMode" });
    }
    const publication = yield* createPublication({
      principal: input.principal,
      providerVmId: input.providerVmId,
      port: input.port,
      accessMode: input.accessMode,
      teamId: input.teamId,
      forwardAuth: input.forwardAuth,
      generatedDomain: input.generatedDomain,
      now,
    });
    // A retry reuses the live publication of that port with its own access; a
    // different access asked for explicitly is refused, never silently ignored.
    if (input.accessMode !== undefined && publication.accessMode !== input.accessMode) {
      return yield* new PublicationConflictError({ reason: "publication_access_mismatch" });
    }
    const minted = yield* createPublicationApiKey({
      principal: input.principal,
      publicationId: publication.id,
      name: input.name,
      expiresAt: input.expiresAt,
      forwardAuth: input.forwardAuth,
      now,
    });
    return { ...minted, publication, url: publication.url } satisfies ProvisionedApi;
  });
}

function mintedKey(row: CloudVmPublicationApiKeyRow, token: string): MintedPublicationApiKey {
  return {
    apiKey: apiKeyDto(row),
    token,
    cookieName: PUBLICATION_API_KEY_COOKIE,
    cookie: `${PUBLICATION_API_KEY_COOKIE}=${token}`,
  };
}
