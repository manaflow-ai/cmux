import { createHash } from "node:crypto";
import { eq } from "drizzle-orm";
import { getStackServerApp, isStackConfigured } from "../../app/lib/stack";
import {
  stackAccessTokenVerifierFromEnv,
  verifyStackAccessTokenLocally,
  type StackAccessTokenIdentity,
} from "../auth/stackAccessToken";
import { hasAuthRateLimitSignal } from "./authErrors";
import { cloudDb } from "../../db/client";
import { accountDeletionTombstones } from "../../db/schema";
import {
  accountDeletionUserHash,
  isBlockingAccountDeletionTombstone,
} from "../account/deletionLock";
import {
  billingPlanIdFromMetadata,
  billingSeatsFromMetadata,
  billingTeamFromUnknown,
  resolveBillingTeam,
  type BillingTeamLike,
} from "../billing/teamResolution";

export type AuthedUser = {
  id: string;
  displayName: string | null;
  primaryEmail: string | null;
  billingCustomerType: "team" | "user";
  billingTeamId: string;
  selectedTeamId: string | null;
  teams: readonly AuthedTeam[];
  teamIds: readonly string[];
  userBillingPlanId: string | null;
  billingPlanId: string | null;
  /** Paid seats on the resolved billing team; null for user billing or unknown. */
  billingSeats: number | null;
};

export type AuthedTeam = {
  id: string;
  displayName: string | null;
  billingPlanId: string | null;
  billingSeats: number | null;
};

export class SubrouterAuthorizationConfigurationError extends Error {
  override readonly name = "SubrouterAuthorizationConfigurationError";
}

export class SubrouterAuthorizationTimeoutError extends Error {
  override readonly name = "SubrouterAuthorizationTimeoutError";
}

export class SubrouterAuthorizationUnavailableError extends Error {
  override readonly name = "SubrouterAuthorizationUnavailableError";
}

/**
 * Stack Auth rejected (or is presumed to be rejecting) verification with a
 * project-wide throttle. The message keeps the "rate limited" wording that
 * `authProviderErrorResponse` and `relayAuthenticationError` detect.
 */
export class StackAuthRateLimitedError extends Error {
  override readonly name = "StackAuthRateLimitedError";
}

export type NativeStackTokens = {
  readonly accessToken: string;
  readonly refreshToken: string;
};

export function parseNativeStackTokens(
  request: Request,
): NativeStackTokens | null {
  const authorization = request.headers.get("authorization");
  const refreshToken = request.headers.get("x-stack-refresh-token")?.trim();
  if (
    !authorization?.toLowerCase().startsWith("bearer ") ||
    !refreshToken
  ) {
    return null;
  }
  const accessToken = authorization.slice("bearer ".length).trim();
  return accessToken ? { accessToken, refreshToken } : null;
}

type VerifyRequestOptions = {
  readonly requestedTeamId?: string | null;
  readonly allowCookie?: boolean;
  readonly allowDeletingAccount?: boolean;
  readonly listAllTeams?: boolean;
  readonly subrouterAuthorizationSignal?: AbortSignal;
};

const DEFAULT_SUBROUTER_STACK_AUTH_TIMEOUT_MS = 10_000;
const MAX_SUBROUTER_STACK_AUTH_TIMEOUT_MS = 30_000;
const MAX_CONCURRENT_STACK_AUTHORIZATION_CALLS = 8;
const MAX_QUEUED_STACK_AUTHORIZATION_CALLS = 32;

// Native-bearer verification cache. Stack Auth rate-limits server-side token verification,
// and the Mac client bursts several /api/vm calls per user action (create → attach → status),
// which surfaced as HTTP 429 rate_limited to end users. Successful verifications are cached
// for a short TTL keyed by a hash of the exact tokens plus the result-affecting options, so a
// burst costs one Stack call. Failures and throttles are never cached, and the cookie and
// subrouter paths are never cached (cookies vary per request; subrouter verification runs
// under its own deadline and may page through every team).
const DEFAULT_AUTH_CACHE_TTL_MS = 30_000;
const MAX_AUTH_CACHE_ENTRIES = 256;

type AuthCacheEntry = {
  readonly user: AuthedUser;
  /** Hash of the exact native access/refresh pair, used for sign-out invalidation. */
  readonly tokenFingerprint: string;
  readonly expiresAt: number;
};

const nativeAuthCache = new Map<string, AuthCacheEntry>();

function authCacheTtlMs(raw = process.env.CMUX_VM_AUTH_CACHE_TTL_MS): number {
  const trimmed = raw?.trim();
  if (trimmed === undefined || trimmed === "") return DEFAULT_AUTH_CACHE_TTL_MS;
  const parsed = Number(trimmed);
  if (!Number.isSafeInteger(parsed) || parsed < 0) return DEFAULT_AUTH_CACHE_TTL_MS;
  return parsed;
}

function nativeAuthCacheKey(
  tokens: NativeStackTokens,
  options: VerifyRequestOptions,
): string {
  const material = [
    tokens.accessToken,
    tokens.refreshToken,
    normalizedOptionalString(options.requestedTeamId) ?? "",
    options.allowDeletingAccount === true ? "1" : "0",
    options.listAllTeams === true ? "1" : "0",
  ].join("\n");
  return createHash("sha256").update(material).digest("hex");
}

function nativeAuthTokenFingerprint(tokens: NativeStackTokens): string {
  return createHash("sha256")
    .update(`${tokens.accessToken}\n${tokens.refreshToken}`)
    .digest("hex");
}

function readNativeAuthCache(key: string): AuthedUser | null {
  const entry = nativeAuthCache.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    nativeAuthCache.delete(key);
    return null;
  }
  return entry.user;
}

function writeNativeAuthCache(
  key: string,
  user: AuthedUser,
  tokens: NativeStackTokens,
  ttlMs: number,
): void {
  if (ttlMs <= 0) return;
  if (nativeAuthCache.size >= MAX_AUTH_CACHE_ENTRIES) {
    const oldest = nativeAuthCache.keys().next().value;
    if (oldest !== undefined) nativeAuthCache.delete(oldest);
  }
  nativeAuthCache.delete(key);
  nativeAuthCache.set(key, {
    user,
    tokenFingerprint: nativeAuthTokenFingerprint(tokens),
    expiresAt: Date.now() + ttlMs,
  });
}

/** Test hook: clear the native verification cache between cases. */
export function clearNativeAuthCacheForTests(): void {
  nativeAuthCache.clear();
}

/**
 * Drop every cached verification for an exact native Stack token pair.
 *
 * Sign-out revokes the Stack session asynchronously, while this process may
 * otherwise continue serving a short-lived positive cache entry. The VM
 * sign-out route calls this immediately after authenticating the request so a
 * second request cannot reuse that entry during the revocation tail.
 */
export function invalidateNativeAuthCacheForTokens(tokens: NativeStackTokens): void {
  const fingerprint = nativeAuthTokenFingerprint(tokens);
  for (const [key, entry] of nativeAuthCache) {
    if (entry.tokenFingerprint === fingerprint) nativeAuthCache.delete(key);
  }
}

// Stack throttles per project, not per caller. Once one native verification is
// throttled, every other native verification from this instance fails the same
// way for the next few seconds, and the Stack SDK retries each of those calls
// against three hosts before giving up. Fail fast during that window so a
// throttled window costs one upstream call per instance instead of multiplying
// the load that caused the throttle. Successful verifications still come from
// the positive cache above; the cookie path is interactive and is never gated.
const STACK_THROTTLE_CIRCUIT_MS = 10_000;
let stackThrottledUntil = 0;

function assertStackNotThrottled(): void {
  const remainingMs = stackThrottledUntil - Date.now();
  if (remainingMs <= 0) return;
  throw new StackAuthRateLimitedError(
    `Stack Auth rate limited; circuit open for ${Math.ceil(remainingMs / 1_000)}s`,
  );
}

function recordStackThrottle(cause: unknown): StackAuthRateLimitedError {
  stackThrottledUntil = Date.now() + STACK_THROTTLE_CIRCUIT_MS;
  return new StackAuthRateLimitedError("Stack Auth rate limited", { cause });
}

/** Test hook: close the Stack throttle circuit between cases. */
export function clearStackThrottleCircuitForTests(): void {
  stackThrottledUntil = 0;
}

let activeStackAuthorizationCalls = 0;
let timedOutStackAuthorizationCalls = 0;
const stackAuthorizationWaiters: Array<{
  readonly signal: AbortSignal;
  readonly resolve: (release: () => void) => void;
  readonly reject: (error: Error) => void;
  readonly abort: () => void;
}> = [];

export async function withSubrouterAuthorizationDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const timeoutMs = subrouterStackAuthorizationTimeoutMs();
  const controller = new AbortController();
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(() => {
      controller.abort();
      reject(new SubrouterAuthorizationTimeoutError(
        "Stack authorization deadline exceeded",
      ));
    }, timeoutMs);
  });
  try {
    return await Promise.race([
      operation(controller.signal),
      deadline,
    ]);
  } finally {
    if (timeout !== undefined) clearTimeout(timeout);
  }
}

export async function verifySubrouterRequest(
  request: Request,
  signal: AbortSignal,
  options: Omit<VerifyRequestOptions, "subrouterAuthorizationSignal"> = {},
): Promise<AuthedUser | null> {
  return verifyRequest(request, {
    ...options,
    subrouterAuthorizationSignal: signal,
  });
}

export function isSubrouterAuthorizationError(
  error: unknown,
): error is
  | SubrouterAuthorizationConfigurationError
  | SubrouterAuthorizationTimeoutError
  | SubrouterAuthorizationUnavailableError {
  return error instanceof SubrouterAuthorizationConfigurationError ||
    error instanceof SubrouterAuthorizationTimeoutError ||
    error instanceof SubrouterAuthorizationUnavailableError;
}

function subrouterStackAuthorizationTimeoutMs(
  raw = process.env.SUBROUTER_STACK_AUTH_TIMEOUT_MS,
): number {
  if (raw === undefined || raw.trim() === "") {
    return DEFAULT_SUBROUTER_STACK_AUTH_TIMEOUT_MS;
  }
  if (!/^[1-9][0-9]*$/.test(raw.trim())) {
    throw new SubrouterAuthorizationConfigurationError(
      "SUBROUTER_STACK_AUTH_TIMEOUT_MS must be a positive integer",
    );
  }
  const timeout = Number(raw);
  if (!Number.isSafeInteger(timeout) || timeout > MAX_SUBROUTER_STACK_AUTH_TIMEOUT_MS) {
    throw new SubrouterAuthorizationConfigurationError(
      `SUBROUTER_STACK_AUTH_TIMEOUT_MS must not exceed ${MAX_SUBROUTER_STACK_AUTH_TIMEOUT_MS}`,
    );
  }
  return timeout;
}

async function stackAuthorizationCall<T>(
  operation: () => Promise<T>,
  signal: AbortSignal | undefined,
): Promise<T> {
  if (!signal) return operation();
  const release = await acquireStackAuthorizationSlot(signal);
  let pending: Promise<T>;
  try {
    pending = Promise.resolve().then(operation);
  } catch (error) {
    release();
    throw new SubrouterAuthorizationUnavailableError(
      error instanceof Error ? error.message : "Stack authorization failed",
    );
  }
  void pending.then(release, release);
  try {
    return await waitForStackAuthorization(pending, signal);
  } catch (error) {
    if (error instanceof SubrouterAuthorizationTimeoutError) {
      markTimedOutStackAuthorizationCall(pending);
      throw error;
    }
    throw new SubrouterAuthorizationUnavailableError(
      error instanceof Error ? error.message : "Stack authorization failed",
    );
  }
}

function acquireStackAuthorizationSlot(
  signal: AbortSignal,
): Promise<() => void> {
  if (signal.aborted) {
    return Promise.reject(new SubrouterAuthorizationTimeoutError(
      "Stack authorization deadline exceeded",
    ));
  }
  // Stack's SDK does not expose a transport AbortSignal. If every underlying
  // call has outlived its caller deadline, fail new work immediately until one
  // settles instead of growing a queue behind an unrecoverable transport.
  if (
    timedOutStackAuthorizationCalls >=
      MAX_CONCURRENT_STACK_AUTHORIZATION_CALLS
  ) {
    return Promise.reject(new SubrouterAuthorizationUnavailableError(
      "Stack authorization circuit is open",
    ));
  }
  if (
    activeStackAuthorizationCalls <
      MAX_CONCURRENT_STACK_AUTHORIZATION_CALLS
  ) {
    activeStackAuthorizationCalls += 1;
    return Promise.resolve(releaseStackAuthorizationSlot);
  }
  if (
    stackAuthorizationWaiters.length >=
      MAX_QUEUED_STACK_AUTHORIZATION_CALLS
  ) {
    return Promise.reject(new SubrouterAuthorizationUnavailableError(
      "Stack authorization queue is full",
    ));
  }
  return new Promise((resolve, reject) => {
    const waiter = {
      signal,
      resolve,
      reject,
      abort: () => {
        const index = stackAuthorizationWaiters.indexOf(waiter);
        if (index >= 0) stackAuthorizationWaiters.splice(index, 1);
        reject(new SubrouterAuthorizationTimeoutError(
          "Stack authorization deadline exceeded",
        ));
      },
    };
    stackAuthorizationWaiters.push(waiter);
    signal.addEventListener("abort", waiter.abort, { once: true });
  });
}

function markTimedOutStackAuthorizationCall(pending: Promise<unknown>): void {
  timedOutStackAuthorizationCalls += 1;
  void pending.then(
    retireTimedOutStackAuthorizationCall,
    retireTimedOutStackAuthorizationCall,
  );
}

function retireTimedOutStackAuthorizationCall(): void {
  timedOutStackAuthorizationCalls = Math.max(
    0,
    timedOutStackAuthorizationCalls - 1,
  );
}

function releaseStackAuthorizationSlot(): void {
  while (stackAuthorizationWaiters.length > 0) {
    const waiter = stackAuthorizationWaiters.shift()!;
    waiter.signal.removeEventListener("abort", waiter.abort);
    if (waiter.signal.aborted) continue;
    waiter.resolve(releaseStackAuthorizationSlot);
    return;
  }
  activeStackAuthorizationCalls = Math.max(
    0,
    activeStackAuthorizationCalls - 1,
  );
}

function waitForStackAuthorization<T>(
  pending: Promise<T>,
  signal: AbortSignal,
): Promise<T> {
  if (signal.aborted) {
    return Promise.reject(new SubrouterAuthorizationTimeoutError(
      "Stack authorization deadline exceeded",
    ));
  }
  return new Promise((resolve, reject) => {
    const abort = () => {
      reject(new SubrouterAuthorizationTimeoutError(
        "Stack authorization deadline exceeded",
      ));
    };
    signal.addEventListener("abort", abort, { once: true });
    void pending.then(
      (value) => {
        signal.removeEventListener("abort", abort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener("abort", abort);
        reject(error);
      },
    );
  });
}

/**
 * Verify the caller's Stack Auth session. Accepts either a cookie (browser path) or a
 * `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>` pair from the
 * native macOS client.
 *
 * Returns the resolved user or null if unauthenticated.
 */
export async function verifyRequest(
  request: Request,
  options: VerifyRequestOptions = {},
): Promise<AuthedUser | null> {
  if (!isStackConfigured()) {
    return null;
  }

  const stackServerApp = getStackServerApp();
  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");

  if (authHeader !== null || refreshHeader !== null) {
    const tokens = parseNativeStackTokens(request);
    if (!tokens) return null;
    const cacheable = options.subrouterAuthorizationSignal === undefined;
    const cacheKey = cacheable ? nativeAuthCacheKey(tokens, options) : null;
    if (cacheKey) {
      const cached = readNativeAuthCache(cacheKey);
      if (cached) return cached;
    }
    // Subrouter calls carry their own deadline and error classes; only the
    // cacheable native path (device registry, iroh broker, relay) is gated.
    // The check runs inside the operation so it is evaluated when the call
    // actually starts, not when it was queued behind the concurrency limiter.
    let user: Awaited<ReturnType<typeof stackServerApp.getUser>>;
    try {
      user = await stackAuthorizationCall(
        () => {
          if (cacheable) assertStackNotThrottled();
          return stackServerApp.getUser({ tokenStore: tokens });
        },
        options.subrouterAuthorizationSignal,
      );
    } catch (error) {
      // The circuit's own fast-fail must not count as a new upstream throttle,
      // or steady retry traffic would hold the circuit open forever.
      if (error instanceof StackAuthRateLimitedError) throw error;
      if (cacheable && hasAuthRateLimitSignal(error)) throw recordStackThrottle(error);
      throw error;
    }
    if (user) {
      const authed = await authedUserFromStackUser(user, options);
      if (authed && cacheKey) {
        writeNativeAuthCache(cacheKey, authed, tokens, authCacheTtlMs());
      }
      return authed;
    }
    // A caller that presents native credentials must succeed or fail as that
    // native session. Falling back to an ambient browser cookie would let an
    // invalid bearer bypass mutation-origin checks.
    return null;
  }

  if (options.allowCookie === false) {
    return null;
  }

  // Fall back to the Next.js cookie flow (when browser hits the route).
  const user = await stackAuthorizationCall(
    () => stackServerApp.getUser({
      tokenStore: request as unknown as {
        headers: { get(name: string): string | null };
      },
    }),
    options.subrouterAuthorizationSignal,
  );
  if (user) {
    return await authedUserFromStackUser(user, options);
  }
  return null;
}

export type VerifiedIdentity = {
  readonly id: string;
  /** How the identity was established; surfaced for logs and tests. */
  readonly source: "access_token" | "stack";
};

type VerifyIdentityOptions = {
  readonly allowCookie?: boolean;
  /**
   * Skip the local token check and ask Stack, so a revoked session is refused
   * immediately. Use for sensitive, low-volume operations.
   */
  readonly requireStackSession?: boolean;
  /** Test seam for the local token verifier. */
  readonly verifyAccessToken?: (
    accessToken: string,
  ) => Promise<StackAccessTokenIdentity | null>;
};

/**
 * Establish only WHO the caller is, for routes that need the user id and
 * nothing else (the iroh trust broker). A native bearer token is verified
 * locally against Stack's published signing keys, so the ~100 req/s of device
 * registration traffic no longer costs one Stack `users/me` call each. Any
 * token the local check cannot accept (expired, unknown key, malformed, keys
 * unavailable) falls back to `verifyRequest`, which asks Stack and refreshes.
 *
 * Trade-off, stated: a session revoked at Stack stays accepted here until its
 * access token expires. Stack access tokens live one hour. Routes that gate
 * money or account mutation must keep using `verifyRequest`.
 */
export async function verifyRequestIdentity(
  request: Request,
  options: VerifyIdentityOptions = {},
): Promise<VerifiedIdentity | null> {
  if (!isStackConfigured()) return null;
  const tokens = parseNativeStackTokens(request);
  if (tokens && !options.requireStackSession) {
    const verifier = options.verifyAccessToken
      ? null
      : stackAccessTokenVerifierFromEnv();
    const local = options.verifyAccessToken
      ? await options.verifyAccessToken(tokens.accessToken)
      : verifier
        ? await verifyStackAccessTokenLocally(tokens.accessToken, verifier)
        : null;
    if (local) return { id: local.userId, source: "access_token" };
  }
  const user = await verifyRequest(request, { allowCookie: options.allowCookie });
  return user ? { id: user.id, source: "stack" } : null;
}

async function authedUserFromStackUser(
  user: StackUserLike,
  options: VerifyRequestOptions,
): Promise<AuthedUser | null> {
  if (!options.allowDeletingAccount && await isAccountDeletionAuthBlocked(user)) {
    return null;
  }

  const selectedTeam = billingTeamFromUnknown(user.selectedTeam);
  const requestedTeamId = normalizedOptionalString(options.requestedTeamId);
  // Full pagination is reserved for the explicit team-picker route. Other
  // callers resolve one requested team with Stack's exact-ID search so shared
  // VM authentication never inherits an unbounded multi-page dependency.
  const needsListedTeams = !selectedTeam ||
    (!!requestedTeamId && requestedTeamId !== selectedTeam.id);
  const listedTeamRaw = options.subrouterAuthorizationSignal === undefined
    ? needsListedTeams && typeof user.listTeams === "function"
      ? await user.listTeams()
      : []
    : options.listAllTeams === true
    ? await listAllStackTeams(user, options.subrouterAuthorizationSignal)
    : requestedTeamId && requestedTeamId !== selectedTeam?.id
    ? await findStackTeam(
      user,
      requestedTeamId,
      options.subrouterAuthorizationSignal,
    )
    : [];
  const listedTeams = listedTeamRaw
    .map(billingTeamFromUnknown)
    .filter((team): team is BillingTeamLike => !!team);
  const teamIds = uniqueStrings([
    selectedTeam?.id,
    ...listedTeams.map((team) => team.id),
  ]);
  const teams = uniqueTeams([selectedTeam, ...listedTeams]);
  const billingTeam = await resolveBillingTeam({
    selectedTeam,
    listTeams: async () => listedTeams,
  });
  const userBillingPlanId = billingPlanIdFromMetadata(user.clientReadOnlyMetadata) ?? null;
  const billingPlanId = billingPlanIdFromMetadata(billingTeam?.clientReadOnlyMetadata) ?? userBillingPlanId;
  const billingSeats = billingSeatsFromMetadata(billingTeam?.clientReadOnlyMetadata);
  const authedTeams = teams.map((team) => ({
    id: team.id,
    displayName: team.displayName,
    billingPlanId: billingPlanIdFromMetadata(team.clientReadOnlyMetadata),
    billingSeats: billingSeatsFromMetadata(team.clientReadOnlyMetadata),
  }));

  return {
    id: user.id,
    displayName: user.displayName,
    primaryEmail: user.primaryEmail,
    billingCustomerType: billingTeam ? "team" : "user",
    billingTeamId: billingTeam?.id ?? user.id,
    selectedTeamId: selectedTeam?.id ?? null,
    teams: authedTeams,
    teamIds,
    userBillingPlanId,
    billingPlanId,
    billingSeats,
  };
}

const MAX_STACK_TEAM_PAGES = 100;
const STACK_TEAM_PAGE_SIZE = 100;

async function listAllStackTeams(
  user: StackUserLike,
  signal: AbortSignal | undefined,
): Promise<readonly unknown[]> {
  if (typeof user.listTeams !== "function") return [];

  const teams: unknown[] = [];
  const seenCursors = new Set<string>();
  let cursor: string | undefined;
  for (let pageIndex = 0; pageIndex < MAX_STACK_TEAM_PAGES; pageIndex++) {
    const page = await stackAuthorizationCall(
      () => user.listTeams!({
        cursor,
        limit: STACK_TEAM_PAGE_SIZE,
      }),
      signal,
    );
    teams.push(...page);
    const nextCursor = normalizedOptionalString(page.nextCursor);
    if (!nextCursor) return teams;
    if (seenCursors.has(nextCursor)) {
      throw new Error("Stack team pagination repeated a cursor");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  }
  throw new Error("Stack team pagination exceeded its page limit");
}

async function findStackTeam(
  user: StackUserLike,
  teamId: string,
  signal: AbortSignal | undefined,
): Promise<readonly unknown[]> {
  if (typeof user.listTeams !== "function") return [];
  const page = await stackAuthorizationCall(
    () => user.listTeams!({
      query: teamId,
      limit: STACK_TEAM_PAGE_SIZE,
    }),
    signal,
  );
  const match = page.find(
    (candidate) => billingTeamFromUnknown(candidate)?.id === teamId,
  );
  return match ? [match] : [];
}

async function isAccountDeletionAuthBlocked(user: StackUserLike): Promise<boolean> {
  if (!hasAccountDeletionMetadataFlag(user.clientReadOnlyMetadata)) return false;
  const userIdHash = accountDeletionUserHash(user.id);
  const [deletion] = await cloudDb()
    .select({
      userIdHash: accountDeletionTombstones.userIdHash,
      status: accountDeletionTombstones.status,
      updatedAt: accountDeletionTombstones.updatedAt,
    })
    .from(accountDeletionTombstones)
    .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
    .limit(1);
  return deletion?.userIdHash === userIdHash &&
    isBlockingAccountDeletionTombstone(deletion);
}

function hasAccountDeletionMetadataFlag(metadata: unknown): boolean {
  return !!metadata &&
    typeof metadata === "object" &&
    !Array.isArray(metadata) &&
    (metadata as { cmuxAccountDeleting?: unknown }).cmuxAccountDeleting === true;
}

type StackUserLike = {
  readonly id: string;
  readonly displayName: string | null;
  readonly primaryEmail: string | null;
  readonly clientReadOnlyMetadata?: unknown;
  readonly selectedTeam?: unknown;
  readonly listTeams?: (
    options?: {
      readonly cursor?: string;
      readonly limit?: number;
      readonly query?: string;
    },
  ) => Promise<readonly unknown[] & { readonly nextCursor?: string | null }>;
};

function uniqueStrings(values: readonly (string | undefined)[]): readonly string[] {
  return [...new Set(values.filter((value): value is string => typeof value === "string" && value.length > 0))];
}

function uniqueTeams(values: readonly (BillingTeamLike | null | undefined)[]): readonly BillingTeamLike[] {
  const teams: BillingTeamLike[] = [];
  const seen = new Set<string>();
  for (const team of values) {
    if (!team || seen.has(team.id)) continue;
    seen.add(team.id);
    teams.push(team);
  }
  return teams;
}

function normalizedOptionalString(value: string | null | undefined): string | null {
  const normalized = value?.trim();
  return normalized ? normalized : null;
}

export function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "content-type": "application/json" },
  });
}
