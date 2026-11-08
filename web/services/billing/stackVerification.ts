/** The server-side subset of a Stack user used by billing mutations. */
export type StackPurchaseUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly primaryEmailAuthEnabled?: boolean;
  readonly emailAuthEnabled?: boolean;
  readonly setPrimaryEmail?: (
    email: string | null,
    options?: { verified?: boolean },
  ) => Promise<void>;
  readonly update?: (options: {
    primaryEmail?: string | null;
    primaryEmailAuthEnabled?: boolean;
    primaryEmailVerified?: boolean;
  }) => Promise<unknown>;
};

/**
 * Mark the email attached to a paid purchase as a verified Stack auth email.
 *
 * Current Stack server users use `setPrimaryEmail` with the SDK's verified
 * flag. Older/mocked server users can use the server update field; only when
 * neither SDK surface is available do we use the centralized REST fallback.
 * Existing primary-email spelling is intentionally preserved.
 */
export async function markPurchaseEmailVerified(
  user: StackPurchaseUser,
  email: string,
): Promise<void> {
  if (user.primaryEmailVerified === true) return;
  const literalEmail = user.primaryEmail?.trim() || email.trim();

  if (typeof user.setPrimaryEmail === "function") {
    try {
      await user.setPrimaryEmail(literalEmail, { verified: true });
      return;
    } catch (error) {
      // A pre-verified-flag SDK can expose setPrimaryEmail but reject the
      // options object. Continue through the centralized server update/API
      // fallback only for that capability mismatch; provider failures remain
      // retryable and are not silently swallowed.
      if (!isUnsupportedVerificationFieldError(error)) throw error;
    }
  }

  if (typeof user.update === "function") {
    try {
      await user.update({ primaryEmailVerified: true });
      return;
    } catch (error) {
      if (!isUnsupportedVerificationFieldError(error)) throw error;
    }
  }

  const { markStackUserEmailVerifiedViaApi } = await import(
    "../../app/lib/stack"
  );
  await markStackUserEmailVerifiedViaApi(user.id, literalEmail);
}

export function isUnsupportedVerificationFieldError(error: unknown): boolean {
  const code =
    error && typeof error === "object"
      ? (error as { code?: unknown; errorCode?: unknown }).code ??
        (error as { errorCode?: unknown }).errorCode
      : undefined;
  if (code === "SCHEMA_ERROR") return true;
  const message = error instanceof Error ? error.message : String(error);
  return /unknown|unsupported|unexpected|invalid.*(primary.?email.?verified|field)|not a function/i.test(
    message,
  );
}
