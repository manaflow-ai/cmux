import type { NextRequest } from "next/server";

/**
 * Rejects a cross-site form POST.
 *
 * Sign-in POSTs carry no session cookie, so the risk is the reverse of normal
 * CSRF: an attacker submitting their own credentials to log a visitor into an
 * account the attacker controls, then watching what that visitor does there.
 * `Sec-Fetch-Site` is the primary signal and every browser that can reach
 * these pages sends it; the `Origin` comparison covers the rest.
 */
export function isSameOriginFormPost(
  request: NextRequest,
  origin: string,
): boolean {
  const fetchSite = request.headers.get("sec-fetch-site");
  if (fetchSite === "cross-site") return false;
  const requestOriginHeader = request.headers.get("origin");
  if (requestOriginHeader && requestOriginHeader !== origin) return false;
  return fetchSite !== null || requestOriginHeader !== null;
}

/** Reads a form value as a trimmed string, treating files as absent. */
export function formString(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

/**
 * A deliberately loose shape check. Address validity is the mail server's
 * call; this only stops an empty or obviously malformed submission from
 * costing a round trip.
 */
export function looksLikeEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value) && value.length <= 254;
}
