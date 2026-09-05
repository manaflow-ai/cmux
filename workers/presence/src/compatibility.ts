/**
 * Headers used only by the temporary compatibility adapter while the direct
 * Hyperdrive backend is being rolled out.  Vercel deployment protection is
 * deliberately bypassed only for an explicitly configured *.vercel.app
 * origin.  A misconfigured origin must never receive this secret.
 */
export function compatibilityProtectionHeaders(
  baseURL: string,
  bypassSecret: string | undefined,
): Record<string, string> {
  const secret = bypassSecret?.trim();
  if (!secret) return {};

  let hostname: string;
  try {
    const url = new URL(baseURL);
    if (url.protocol !== "https:") return {};
    hostname = url.hostname.toLowerCase();
  } catch {
    return {};
  }

  // Deployment URLs and the staging alias are both under vercel.app.  Keep
  // this allowlist narrower than "any configured origin" so an accidental
  // environment change cannot exfiltrate the Vercel secret.
  if (!hostname.endsWith(".vercel.app")) return {};
  return { "x-vercel-protection-bypass": secret };
}

/**
 * Validate the compatibility upstream before a session ticket is placed on
 * the request. Only HTTPS origins are allowed, and URL credentials/query
 * state is rejected so an operator typo cannot redirect a bearer-equivalent
 * ticket to an unexpected endpoint.
 */
export function validatedCompatibilityBaseURL(baseURL: string): string | null {
  try {
    const url = new URL(baseURL);
    if (url.protocol !== "https:" || !url.hostname
      || url.username || url.password || url.search || url.hash) {
      return null;
    }
    return url.toString().replace(/\/+$/, "");
  } catch {
    return null;
  }
}
