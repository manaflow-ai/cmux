/** Where a signed-in user lands when the request names no destination. */
export const DEFAULT_AFTER_AUTH_PATH = "/handler/after-sign-in";

/**
 * Narrows an attacker-controllable `after_auth_return_to` to a same-origin
 * path. Anything absolute, protocol-relative, or pointing at another host is
 * discarded, so the sign-in page can never be turned into an open redirect.
 */
export function safeReturnToPath(
  value: string | null | undefined,
  fallback: string = DEFAULT_AFTER_AUTH_PATH,
): string {
  if (!value) return fallback;
  if (!value.startsWith("/") || value.startsWith("//")) return fallback;
  // A backslash is a path separator to some URL parsers but not others, and
  // the disagreement is exactly what host-confusion payloads exploit.
  if (value.includes("\\")) return fallback;
  return value;
}

/** Rebuilds an auth page URL while preserving the destination and prefill. */
export function authPageHref(
  path: string,
  params: {
    readonly returnTo?: string | null;
    readonly email?: string | null;
    readonly error?: string | null;
    readonly nonce?: string | null;
    readonly method?: string | null;
  },
): string {
  const query = new URLSearchParams();
  if (params.returnTo) query.set("after_auth_return_to", params.returnTo);
  if (params.email) query.set("email", params.email);
  if (params.nonce) query.set("nonce", params.nonce);
  if (params.method) query.set("method", params.method);
  if (params.error) query.set("error", params.error);
  const serialized = query.toString();
  return serialized ? `${path}?${serialized}` : path;
}
