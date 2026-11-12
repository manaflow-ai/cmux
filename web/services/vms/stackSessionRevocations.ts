import { env } from "../../app/env";
import { stackApiBaseURL } from "../auth/stackApiBaseURL";

/**
 * Revoking a Cloud access grant also revokes the Stack sessions that enrolled
 * it. The grant and its tunnels are cut in our database first, so the Mac
 * loses Cloud network access no matter what Stack answers, and the sessions
 * are queued in `stack_session_revocations` in that same transaction. They
 * are revoked with the server key (`DELETE /auth/sessions/{id}`), which needs
 * no user token, so a revocation Stack throttled or failed is retried by the
 * vm-reconcile cron. A row is deleted when Stack accepts; after the attempt
 * cap or 24 hours it is marked given up and reported.
 */
export type StackSessionRevocationRow = {
  readonly stackSessionId: string;
  readonly userId: string;
  readonly attempts: number;
};

export type StackSessionRevocationFailure = {
  readonly attempts: number;
  /** True when this failure made the row terminal (cap or age reached). */
  readonly gaveUp: boolean;
};

export type StackSessionRevocationStore = {
  /**
   * Claim due rows for one cron run: not given up, due, and not held by
   * another run's lease. Concurrent runs claim disjoint rows.
   */
  claimDue(now: Date, limit: number, leaseUntil: Date): Promise<readonly StackSessionRevocationRow[]>;
  /** Open (not given up) rows among these session ids, for the request's own first attempt. */
  listOpen(stackSessionIds: readonly string[]): Promise<readonly StackSessionRevocationRow[]>;
  /** Stack accepted: the row is done and deleted. */
  markRevoked(stackSessionId: string): Promise<void>;
  /** Count a failed attempt, schedule the next one, and stop at the cap or age limit. */
  recordFailure(stackSessionId: string, input: {
    readonly now: Date;
    readonly error: string;
    readonly policy: StackSessionRevocationRetryPolicy;
  }): Promise<StackSessionRevocationFailure | null>;
};

/** Revoke one session at Stack. Resolves when Stack no longer has it; throws otherwise. */
export type StackSessionRevoker = (stackSessionId: string) => Promise<void>;

export type StackSessionRevocationRetryPolicy = {
  readonly baseDelayMs: number;
  readonly maxDelayMs: number;
  readonly maxAttempts: number;
  readonly maxAgeMs: number;
};

/** 1, 2, 4 ... minutes, capped at one hour; give up after 20 attempts or 24 hours. */
export const STACK_SESSION_REVOCATION_POLICY: StackSessionRevocationRetryPolicy = {
  baseDelayMs: 60_000,
  maxDelayMs: 60 * 60_000,
  maxAttempts: 20,
  maxAgeMs: 24 * 60 * 60_000,
};

/**
 * Queued rows become due for the cron this long after the grant revocation,
 * so the request's own first attempt and a cron run do not overlap. If the
 * request dies before attempting, the cron picks the rows up then.
 */
export const FIRST_CRON_RETRY_DELAY_MS = 2 * 60_000;

/** How long one cron run holds the rows it claimed. Longer than a run's attempts. */
export const CRON_CLAIM_LEASE_MS = 2 * 60_000;

/** Rows per cron run; attempts run concurrently, each bounded by a 10 s timeout. */
export const CRON_CLAIM_LIMIT = 20;

export type SessionRevocationOutcome = "revoked" | "pending";

export type GiveUpReporter = (row: StackSessionRevocationRow & { readonly attempts: number; readonly error: string }) => void;

/**
 * The request's first attempt at the sessions its grant revocation queued.
 * Answers `pending` while any session is still waiting for Stack, so the
 * caller never reports success it does not have.
 */
export async function revokeAccessGrantStackSessions(input: {
  readonly stackSessionIds: readonly string[];
  readonly store: StackSessionRevocationStore;
  readonly revoke: StackSessionRevoker;
  readonly onGiveUp?: GiveUpReporter;
  readonly now?: () => Date;
}): Promise<SessionRevocationOutcome> {
  if (input.stackSessionIds.length === 0) return "revoked";
  const open = await input.store.listOpen(input.stackSessionIds);
  const results = await Promise.all(open.map((row) =>
    attemptRevocation(row, input.store, input.revoke, input.now ?? (() => new Date()), input.onGiveUp)));
  return results.every((revoked) => revoked) ? "revoked" : "pending";
}

/** The cron step: claim due revocations and retry them. */
export async function retryPendingStackSessionRevocations(input: {
  readonly store: StackSessionRevocationStore;
  readonly revoke: StackSessionRevoker;
  readonly onGiveUp?: GiveUpReporter;
  readonly now?: () => Date;
  readonly limit?: number;
}): Promise<{ readonly attempted: number; readonly revoked: number; readonly pending: number }> {
  const now = input.now ?? (() => new Date());
  const startedAt = now();
  const claimed = await input.store.claimDue(
    startedAt,
    input.limit ?? CRON_CLAIM_LIMIT,
    new Date(startedAt.getTime() + CRON_CLAIM_LEASE_MS),
  );
  const results = await Promise.all(claimed.map((row) =>
    attemptRevocation(row, input.store, input.revoke, now, input.onGiveUp)));
  const revoked = results.filter(Boolean).length;
  return { attempted: claimed.length, revoked, pending: claimed.length - revoked };
}

async function attemptRevocation(
  row: StackSessionRevocationRow,
  store: StackSessionRevocationStore,
  revoke: StackSessionRevoker,
  now: () => Date,
  onGiveUp: GiveUpReporter | undefined,
): Promise<boolean> {
  try {
    await revoke(row.stackSessionId);
  } catch (error) {
    const summary = revocationErrorSummary(error);
    const failure = await store.recordFailure(row.stackSessionId, {
      now: now(),
      error: summary,
      policy: STACK_SESSION_REVOCATION_POLICY,
    });
    // Reported once, on the failure that made the row terminal.
    if (failure?.gaveUp) onGiveUp?.({ ...row, attempts: failure.attempts, error: summary });
    return false;
  }
  await store.markRevoked(row.stackSessionId);
  return true;
}

function revocationErrorSummary(error: unknown): string {
  const status = (error as { status?: unknown } | null)?.status;
  const name = error instanceof Error ? error.name : typeof error;
  return typeof status === "number" ? `${name}: HTTP ${status}` : name;
}

/**
 * Stack's known error for a session (refresh token) that no longer exists or
 * expired: there is nothing left to revoke. (The SDK's known-error list has no
 * separate session-not-found code.)
 */
const GONE_SESSION_ERRORS = new Set(["REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED"]);

/**
 * The exact request the Stack SDK sends for `ServerUser.revokeSession(id)`
 * (`HexclaveServerInterface.deleteServerSession`): `DELETE
 * /api/v1/auth/sessions/{id}` with server access headers and no body or
 * `user_id`; the session id alone names the session.
 */
export function stackServerSessionRevoker(fetchImpl: typeof fetch = fetch): StackSessionRevoker {
  return async (stackSessionId) => {
    const projectId = env.NEXT_PUBLIC_STACK_PROJECT_ID;
    const secretServerKey = env.STACK_SECRET_SERVER_KEY;
    if (!projectId || !secretServerKey) throw new Error("Stack Auth is not configured");
    const base = stackApiBaseURL();
    const url = `${/\/api\/v1$/u.test(base) ? base : `${base}/api/v1`}/auth/sessions/${encodeURIComponent(stackSessionId)}`;
    const response = await fetchImpl(url, {
      method: "DELETE",
      headers: {
        "x-hexclave-access-type": "server",
        "x-hexclave-project-id": projectId,
        "x-hexclave-secret-server-key": secretServerKey,
      },
      signal: AbortSignal.timeout(10_000),
      cache: "no-store",
    });
    await response.body?.cancel();
    if (response.ok) return;
    const knownError = response.headers.get("x-hexclave-known-error") ?? response.headers.get("x-stack-known-error");
    if (knownError && GONE_SESSION_ERRORS.has(knownError)) return;
    // No body in the error: Stack can echo account data.
    throw Object.assign(new Error("Stack session revocation failed"), { status: response.status });
  };
}
