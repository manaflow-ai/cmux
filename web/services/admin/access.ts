// Admin access for the cmux dashboard.
//
// An admin is a signed-in, non-anonymous Stack user whose VERIFIED primary
// email is on one of the company domains below. Verification is required: a
// password sign-up can claim any address until the verification link is used,
// so an unverified company email must never open the admin surface. Stack only
// marks an email verified after the mailbox owner clicks the link, or an OAuth
// provider vouches for it, so the gate reduces to "controls a mailbox on one
// of these domains".

export const ADMIN_EMAIL_DOMAINS = ["cmux.com", "manaflow.ai", "manaflow.com"] as const;

export type AdminAccessUser = {
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
  readonly isAnonymous?: boolean;
};

/**
 * Domain-only check. Callers must also require a verified, non-anonymous user.
 *
 * The comparison is an exact ASCII match on the part after the last "@".
 * There is no Unicode normalization, IDN decoding, or subdomain matching, so
 * lookalike domains (Cyrillic letters, `manaflow.ai.evil.com`,
 * `sub.manaflow.ai`, trailing dots) all fail. The local part must be plain:
 * no quotes, whitespace, or extra "@" that could make the domain ambiguous.
 */
export function isAdminEmail(email: string | null | undefined): boolean {
  if (typeof email !== "string") return false;
  const normalized = email.trim();
  if (normalized.length === 0 || normalized.length > 254) return false;
  if (!/^[\x21-\x7e]+$/.test(normalized)) return false; // printable ASCII only
  const at = normalized.lastIndexOf("@");
  if (at <= 0 || at === normalized.length - 1) return false;
  const local = normalized.slice(0, at);
  const domain = normalized.slice(at + 1).toLowerCase();
  if (!isPlainEmailLocalPart(local)) return false;
  if (!/^[a-z0-9.-]+$/.test(domain)) return false;
  return (ADMIN_EMAIL_DOMAINS as readonly string[]).includes(domain);
}

export function isAdminUser(user: AdminAccessUser | null | undefined): boolean {
  if (!user) return false;
  if (user.isAnonymous !== false) return false;
  if (user.primaryEmailVerified !== true) return false;
  return isAdminEmail(user.primaryEmail);
}

/**
 * Unquoted RFC 5322 local part: letters, digits, and the plain special
 * characters. No whitespace, quotes, backslashes, or "@", so the domain after
 * the last "@" is unambiguous.
 */
export function isPlainEmailLocalPart(local: string): boolean {
  return local.length > 0 && local.length <= 64 && /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~.-]+$/.test(local);
}
