/**
 * The dashboard's Delete account: `DELETE /api/account`, the same server path
 * the iPhone app uses, so a web deletion runs the whole cmux cleanup (Cloud
 * machines, devices, vault, billing, the App Store unlink) before the
 * sign-in service deletes the user. The route takes the session's native
 * tokens (bearer + refresh), not the cookie.
 */

export type AccountDeletionFailure = "signed_out" | "pending" | "retryable" | "failed";

export class AccountDeletionRequestError extends Error {
  constructor(readonly reason: AccountDeletionFailure) {
    super(`account deletion failed: ${reason}`);
    this.name = "AccountDeletionRequestError";
  }
}

type SessionTokens = { readonly accessToken?: string | null; readonly refreshToken?: string | null };
type DeletionSession = { getAuthJson(): Promise<SessionTokens> };
type DeletionFetch = (url: string, init: RequestInit) => Promise<Response>;

const RETRYABLE_STATUSES = new Set([409, 425, 429, 502, 503, 504]);

/**
 * Resolves once the account is deleted. A 202 with `cleanupIncomplete` is a
 * deleted account whose follow-up cleanup the server finishes on its own; a
 * 202 with `deletionPending` is another deletion of this account still
 * running, which is not done yet. Throws {@link AccountDeletionRequestError}.
 */
export async function deleteAccountThroughCmux(
  session: DeletionSession,
  fetchImpl: DeletionFetch = (url, init) => fetch(url, init),
): Promise<void> {
  const { accessToken, refreshToken } = await session.getAuthJson();
  if (!accessToken || !refreshToken) throw new AccountDeletionRequestError("signed_out");
  let response: Response;
  try {
    response = await fetchImpl("/api/account", {
      method: "DELETE",
      headers: { authorization: `Bearer ${accessToken}`, "x-stack-refresh-token": refreshToken },
      cache: "no-store",
    });
  } catch {
    // Offline, or the connection dropped. Deletion is idempotent on the
    // server, so trying again is safe.
    throw new AccountDeletionRequestError("retryable");
  }
  const body = (await response.json().catch(() => null)) as { deletionPending?: unknown; retryable?: unknown } | null;
  if (response.ok) {
    if (body?.deletionPending === true) throw new AccountDeletionRequestError("pending");
    return;
  }
  if (response.status === 401) throw new AccountDeletionRequestError("signed_out");
  if (RETRYABLE_STATUSES.has(response.status) || body?.retryable === true) {
    throw new AccountDeletionRequestError("retryable");
  }
  throw new AccountDeletionRequestError("failed");
}
