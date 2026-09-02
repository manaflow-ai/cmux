// Admin access for the cmux dashboard.
//
// An admin is a signed-in, non-anonymous Stack user whose verified primary
// email is on the manaflow.ai domain. Verification is required: a password
// sign-up can claim any address until the verification link is used, so an
// unverified manaflow.ai email must not open the admin surface.

export const ADMIN_EMAIL_DOMAIN = "manaflow.ai";

export type AdminAccessUser = {
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
};

/** Domain-only check. Callers must also require a verified, non-anonymous user. */
export function isAdminEmail(email: string | null | undefined): boolean {
  if (typeof email !== "string") return false;
  const normalized = email.trim().toLowerCase();
  const at = normalized.lastIndexOf("@");
  if (at <= 0 || at === normalized.length - 1) return false;
  return normalized.slice(at + 1) === ADMIN_EMAIL_DOMAIN;
}

export function isAdminUser(user: AdminAccessUser | null | undefined): boolean {
  if (!user) return false;
  if (user.isAnonymous === true) return false;
  if (user.primaryEmailVerified !== true) return false;
  return isAdminEmail(user.primaryEmail);
}
