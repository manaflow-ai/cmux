import { env } from "../../app/env";
import { stackApiBaseURL } from "../auth/stackApiBaseURL";

/**
 * Revoking a Cloud access grant also revokes the Stack sessions that enrolled
 * it. The grant and its tunnels are cut in our database first, so the Mac
 * loses Cloud network access no matter what Stack answers. The Stack sessions
 * are revoked with the server key (`DELETE /auth/sessions/{id}`), which needs
 * no user token, so a revocation Stack throttled or failed can be retried
 * later by the cron. Every session is recorded before the first attempt; the
 * route reports `pending` until Stack has accepted every one.
 */
export type StackSessionRevocationRow = {
  readonly stackSessionId: string;
  readonly userId: string;
  readonly attempts: number;
};

export type StackSessionRevocationStore = {
  /** Record sessions to revoke. An already recorded session is left as is. */
  enqueue(input: {
    readonly userId: string;
    readonly accessGrantId: string | null;
    readonly stackSessionIds: readonly string[];
  }): Promise<void>;
  /** Rows not yet revoked whose next attempt is due, oldest first. */
  listDue(now: Date, limit: number): Promise<readonly StackSessionRevocationRow[]>;
  /** Rows not yet revoked among these session ids. */
  listOpen(stackSessionIds: readonly string[]): Promise<readonly StackSessionRevocationRow[]>;
  markRevoked(stackSessionId: string, at: Date): Promise<void>;
  markFailed(stackSessionId: string, input: { readonly attempts: number; readonly nextAttemptAt: Date; readonly error: string }): Promise<void>;
};

/** Revoke one session at Stack. Resolves when Stack no longer has it; throws otherwise. */
export type StackSessionRevoker = (stackSessionId: string) => Promise<void>;

export type SessionRevocationOutcome = "revoked" | "pending";

const RETRY_BASE_MS = 60_000;
const RETRY_MAX_MS = 60 * 60_000;

/** Bounded exponential backoff: 1, 2, 4 ... minutes, never more than an hour. */
export function nextRevocationAttemptAt(now: Date, attempts: number): Date {
  const delay = Math.min(RETRY_BASE_MS * 2 ** Math.max(0, attempts - 1), RETRY_MAX_MS);
  return new Date(now.getTime() + delay);
}

/**
 * Record, then try once now. Answers `pending` when any session is still
 * waiting for Stack, so the caller never reports success it does not have.
 */
export async function revokeAccessGrantStackSessions(input: {
  readonly userId: string;
  readonly accessGrantId: string | null;
  readonly stackSessionIds: readonly string[];
  readonly store: StackSessionRevocationStore;
  readonly revoke: StackSessionRevoker;
  readonly now?: () => Date;
}): Promise<SessionRevocationOutcome> {
  if (input.stackSessionIds.length === 0) return "revoked";
  await input.store.enqueue({
    userId: input.userId,
    accessGrantId: input.accessGrantId,
    stackSessionIds: input.stackSessionIds,
  });
  const open = await input.store.listOpen(input.stackSessionIds);
  const results = await Promise.all(open.map((row) => attemptRevocation(row, input.store, input.revoke, input.now)));
  return results.every((revoked) => revoked) ? "revoked" : "pending";
}

/** The cron step: retry due revocations, bounded per run. */
export async function retryPendingStackSessionRevocations(input: {
  readonly store: StackSessionRevocationStore;
  readonly revoke: StackSessionRevoker;
  readonly now?: () => Date;
  readonly limit?: number;
}): Promise<{ readonly attempted: number; readonly revoked: number; readonly pending: number }> {
  const now = input.now ?? (() => new Date());
  const due = await input.store.listDue(now(), input.limit ?? 100);
  let revoked = 0;
  for (const row of due) {
    if (await attemptRevocation(row, input.store, input.revoke, now)) revoked += 1;
  }
  return { attempted: due.length, revoked, pending: due.length - revoked };
}

async function attemptRevocation(
  row: StackSessionRevocationRow,
  store: StackSessionRevocationStore,
  revoke: StackSessionRevoker,
  now: () => Date = () => new Date(),
): Promise<boolean> {
  try {
    await revoke(row.stackSessionId);
  } catch (error) {
    const attempts = row.attempts + 1;
    await store.markFailed(row.stackSessionId, {
      attempts,
      nextAttemptAt: nextRevocationAttemptAt(now(), attempts),
      error: revocationErrorSummary(error),
    });
    return false;
  }
  await store.markRevoked(row.stackSessionId, now());
  return true;
}

function revocationErrorSummary(error: unknown): string {
  const status = (error as { status?: unknown } | null)?.status;
  const name = error instanceof Error ? error.name : typeof error;
  return typeof status === "number" ? `${name}: HTTP ${status}` : name;
}

/** Stack's known error for a session that no longer exists: revoked already. */
const GONE_SESSION_ERRORS = new Set(["SESSION_NOT_FOUND", "REFRESH_TOKEN_NOT_FOUND_OR_EXPIRED"]);

/** `DELETE /auth/sessions/{id}` with the server key, the SDK's `ServerUser.revokeSession`. */
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
        "x-stack-access-type": "server",
        "x-stack-project-id": projectId,
        "x-stack-secret-server-key": secretServerKey,
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
