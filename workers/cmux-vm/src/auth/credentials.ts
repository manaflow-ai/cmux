/**
 * Credential checks behind the Authentication middleware: Stack Auth session
 * tokens (verified locally against Stack's JWKS), team membership (Stack server
 * API), and cmux VM API keys (looked up by SHA-256 hash; the key itself is
 * never stored).
 */
import { Context, Data, Effect, Layer, Redacted, Schema } from "effect";
import { createLocalJWKSet, errors as joseErrors, jwtVerify, type JSONWebKeySet, type JWTVerifyGetKey } from "jose";
import { TenantId, UserId } from "../lib/ids.ts";
import { MEMBERSHIP_POSITIVE_TTL_MS, MembershipCache, type MembershipCacheService } from "./membership-cache.ts";

export const API_KEY_PREFIX = "cmuxvm_sk_";
const API_KEY_PATTERN = /^cmuxvm_sk_[A-Za-z0-9_-]{43}$/;

export const isApiKeyShaped = (token: string): boolean => API_KEY_PATTERN.test(token);

/** Lowercase hex SHA-256 of the full key string. */
export const hashApiKey = (key: string): Effect.Effect<string> =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(key))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

/** A new API key: the prefix plus 32 random bytes, base64url. Only its hash is stored. */
export const generateApiKey = (): string => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const base64 = btoa(String.fromCharCode(...bytes));
  return API_KEY_PREFIX + base64.replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
};

/** The token was presented but is not a valid session. */
export class SessionRejected extends Data.TaggedError("SessionRejected")<{ readonly reason: string }> {}
/** Stack (keys or API) could not be reached; says nothing about the caller. */
export class IdentityUnavailable extends Data.TaggedError("IdentityUnavailable")<{ readonly reason: string }> {}

export interface SessionVerifierService {
  readonly verify: (token: Redacted.Redacted<string>, now: Date) => Effect.Effect<UserId, SessionRejected | IdentityUnavailable>;
}
export class SessionVerifier extends Context.Tag("cmux-vm/SessionVerifier")<SessionVerifier, SessionVerifierService>() {}

export interface TeamMembershipService {
  readonly isMember: (tenantId: TenantId, userId: UserId) => Effect.Effect<boolean, IdentityUnavailable>;
}
export class TeamMembership extends Context.Tag("cmux-vm/TeamMembership")<TeamMembership, TeamMembershipService>() {}

export interface StackConfig {
  /** Stack API origin, e.g. https://api.stack-auth.com, HTTPS, no path. */
  readonly apiUrl: string;
  readonly projectId: string;
}

const stackOrigin = (apiUrl: string): string => {
  const url = new URL(apiUrl);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("Stack API URL must be a bare HTTPS origin");
  }
  return url.origin;
};

const isTokenRejection = (error: unknown): boolean =>
  error instanceof joseErrors.JWTExpired ||
  error instanceof joseErrors.JWTClaimValidationFailed ||
  error instanceof joseErrors.JWTInvalid ||
  error instanceof joseErrors.JWSInvalid ||
  error instanceof joseErrors.JWSSignatureVerificationFailed ||
  error instanceof joseErrors.JOSEAlgNotAllowed ||
  error instanceof joseErrors.JOSENotSupported ||
  error instanceof joseErrors.JWKSNoMatchingKey ||
  error instanceof joseErrors.JWKSMultipleMatchingKeys;

const looksLikeCompactJws = (value: string): boolean => {
  if (value.length < 20 || value.length > 8192) return false;
  const parts = value.split(".");
  return parts.length === 3 && parts.every((part) => part.length > 0);
};

const JWKS_MAX_AGE_MS = 10 * 60 * 1000;
const JWKS_REFRESH_COOLDOWN_MS = 30 * 1000;

const optionalString = Schema.optionalWith(Schema.String, { exact: true });
/** The public JWK fields jose reads for ES256 (and RSA, for completeness). */
const Jwk = Schema.Struct({
  kty: optionalString,
  crv: optionalString,
  x: optionalString,
  y: optionalString,
  n: optionalString,
  e: optionalString,
  kid: optionalString,
  alg: optionalString,
  use: optionalString,
});
const JwksDocument = Schema.Struct({ keys: Schema.mutable(Schema.Array(Jwk)) });

/**
 * Stack's JWKS, cached as data (never as a pending promise): a Worker must
 * not await I/O that another request started. Each fetch happens inside the
 * request that needs it; an unknown `kid` refetches at most every 30 s.
 */
function stackJwks(url: URL, send: (request: Request) => Promise<Response>): JWTVerifyGetKey {
  let cached: { readonly verify: JWTVerifyGetKey; readonly fetchedAt: number } | undefined;
  const refresh = async (): Promise<JWTVerifyGetKey> => {
    const response = await send(new Request(url, { headers: { accept: "application/json" }, redirect: "manual", signal: AbortSignal.timeout(3000) }));
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`jwks ${response.status}`);
    }
    const document: JSONWebKeySet = Schema.decodeUnknownSync(JwksDocument)(await response.json());
    cached = { verify: createLocalJWKSet(document), fetchedAt: Date.now() };
    return cached.verify;
  };
  return async (header, token) => {
    const current = cached !== undefined && Date.now() - cached.fetchedAt < JWKS_MAX_AGE_MS ? cached : undefined;
    const verify = current?.verify ?? (await refresh());
    try {
      return await verify(header, token);
    } catch (error) {
      if (!(error instanceof joseErrors.JWKSNoMatchingKey) || current === undefined) throw error;
      if (Date.now() - current.fetchedAt < JWKS_REFRESH_COOLDOWN_MS) throw error;
      return (await refresh())(header, token);
    }
  };
}

/**
 * Stack signs access tokens with ES256 under its project issuer and audience.
 * `getKey` defaults to Stack's published JWKS for the project.
 */
export function makeStackSessionVerifier(
  config: StackConfig & { readonly getKey?: JWTVerifyGetKey; readonly fetch?: (request: Request) => Promise<Response> },
): SessionVerifierService {
  const origin = stackOrigin(config.apiUrl);
  const issuer = `${origin}/api/v1/projects/${config.projectId}`;
  const getKey =
    config.getKey ?? stackJwks(new URL(`${issuer}/.well-known/jwks.json`), config.fetch ?? ((request) => fetch(request)));
  const decodeUser = Schema.decodeUnknownOption(UserId);

  return {
    verify: (token, now) =>
      Effect.gen(function* () {
        const raw = Redacted.value(token);
        if (!looksLikeCompactJws(raw)) return yield* Effect.fail(new SessionRejected({ reason: "malformed" }));
        const { payload } = yield* Effect.tryPromise({
          try: () =>
            jwtVerify(raw, getKey, {
              algorithms: ["ES256"],
              issuer,
              audience: config.projectId,
              clockTolerance: 60,
              currentDate: now,
              requiredClaims: ["sub", "exp"],
            }),
          catch: (error) =>
            isTokenRejection(error)
              ? new SessionRejected({ reason: "invalid" })
              : new IdentityUnavailable({ reason: "jwks" }),
        });
        if (payload["project_id"] !== undefined && payload["project_id"] !== config.projectId) {
          return yield* Effect.fail(new SessionRejected({ reason: "project" }));
        }
        if (payload["is_anonymous"] === true) return yield* Effect.fail(new SessionRejected({ reason: "anonymous" }));
        const user = decodeUser(payload.sub);
        if (user._tag === "None") return yield* Effect.fail(new SessionRejected({ reason: "subject" }));
        return user.value;
      }),
  };
}

const TeamsResponse = Schema.Struct({ items: Schema.Array(Schema.Struct({ id: Schema.String })) });

/**
 * Team membership through the Stack server API, behind the shared positive
 * cache (mesh M4, cx-0op.7): a "member" answer is trusted for 60 s, "not a
 * member" is never cached, and the Stack team-membership webhook revokes an
 * entry for every isolate at once. A cache that cannot be read or written is
 * skipped: Stack itself answers, so a cache failure never admits anyone.
 */
export function makeStackTeamMembership(
  config: StackConfig & {
    readonly serverKey: Redacted.Redacted<string>;
    readonly cache: MembershipCacheService;
    readonly fetch?: (request: Request) => Promise<Response>;
    /** The clock, in ms (tests); defaults to Date.now. */
    readonly now?: () => number;
  },
): TeamMembershipService {
  const origin = stackOrigin(config.apiUrl);
  const send = config.fetch ?? ((request: Request) => fetch(request));
  const clock = config.now ?? (() => Date.now());
  const decode = Schema.decodeUnknown(TeamsResponse);
  const lookup = (tenantId: TenantId, userId: UserId): Effect.Effect<boolean, IdentityUnavailable> =>
    Effect.gen(function* () {
      const askedAt = new Date(clock());
      const hit = yield* config.cache
        .fresh(tenantId, userId, new Date(askedAt.getTime() - MEMBERSHIP_POSITIVE_TTL_MS))
        .pipe(Effect.orElseSucceed(() => false));
      if (hit) return true;
      const member = yield* fetchMembership(tenantId, userId);
      if (member) yield* config.cache.rememberMember(tenantId, userId, askedAt).pipe(Effect.ignore);
      return member;
    });
  const fetchMembership = (tenantId: TenantId, userId: UserId): Effect.Effect<boolean, IdentityUnavailable> =>
      Effect.tryPromise({
        try: async () => {
          const url = new URL("/api/v1/teams", origin);
          url.searchParams.set("user_id", userId);
          const response = await send(
            new Request(url, {
              headers: {
                "x-stack-access-type": "server",
                "x-stack-project-id": config.projectId,
                "x-stack-secret-server-key": Redacted.value(config.serverKey),
                accept: "application/json",
              },
              redirect: "manual",
              signal: AbortSignal.timeout(5000),
            }),
          );
          if (!response.ok) {
            await response.body?.cancel();
            throw new Error(`stack ${response.status}`);
          }
          const body: unknown = await response.json();
          return body;
        },
        catch: () => new IdentityUnavailable({ reason: "stack" }),
      }).pipe(
        Effect.flatMap((body) => decode(body).pipe(Effect.mapError(() => new IdentityUnavailable({ reason: "stack-shape" })))),
        Effect.map((teams) => teams.items.some((team) => team.id === tenantId)),
      );
  return { isMember: lookup };
}

export const stackLayers = (
  config: StackConfig & { readonly serverKey: Redacted.Redacted<string> },
): Layer.Layer<SessionVerifier | TeamMembership, never, MembershipCache> =>
  Layer.merge(
    Layer.succeed(SessionVerifier, makeStackSessionVerifier(config)),
    Layer.effect(
      TeamMembership,
      Effect.map(MembershipCache, (cache) => makeStackTeamMembership({ ...config, cache })),
    ),
  );

export const decodeTenantId = Schema.decodeUnknownOption(TenantId);
