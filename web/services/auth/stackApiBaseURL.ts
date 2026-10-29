/**
 * Origin of the Stack (Hexclave) API for our own server-key REST helpers
 * (webhook mirror reads, user PATCH, invitation codes), with no trailing
 * slash. It resolves exactly like the Stack SDK's server app, so every
 * request we send goes to the same host as the SDK's: the server-side URL
 * variables first, then the shared ones, then the SDK default
 * `https://api.hexclave.com`. `STACK_API_BASE_URL` is a cmux-only override
 * and wins. HTTPS only.
 *
 * Until 2026-10-13 this defaulted to `https://api.stack-auth.com` while the
 * SDK used `api.hexclave.com`; with no URL variable set in production, the
 * webhook's reads went to the other host and were throttled far more often.
 */
const SDK_SERVER_URL_VARIABLES = [
  "HEXCLAVE_API_URL_SERVER",
  "NEXT_PUBLIC_HEXCLAVE_API_URL_SERVER",
  "STACK_API_URL_SERVER",
  "NEXT_PUBLIC_STACK_API_URL_SERVER",
  "SERVER_STACK_API_URL",
  "NEXT_PUBLIC_SERVER_STACK_API_URL",
  "SERVER_HEXCLAVE_API_URL",
  "NEXT_PUBLIC_SERVER_HEXCLAVE_API_URL",
] as const;

const SDK_SHARED_URL_VARIABLES = [
  "HEXCLAVE_API_URL",
  "NEXT_PUBLIC_HEXCLAVE_API_URL",
  "STACK_API_URL",
  "NEXT_PUBLIC_STACK_API_URL",
  "HEXCLAVE_URL",
  "NEXT_PUBLIC_HEXCLAVE_URL",
  "STACK_URL",
  "NEXT_PUBLIC_STACK_URL",
] as const;

const SDK_DEFAULT_API_URL = "https://api.hexclave.com";

export function stackApiBaseURL(): string {
  const configured = process.env.STACK_API_BASE_URL?.trim() ||
    firstConfigured(SDK_SERVER_URL_VARIABLES) ||
    firstConfigured(SDK_SHARED_URL_VARIABLES) ||
    SDK_DEFAULT_API_URL;
  return validatedOrigin(configured);
}

/**
 * Origin that Stack access tokens name in `iss`
 * (`<origin>/api/v1/projects/<id>`) and that serves their JWKS. Stack still
 * issues `https://api.stack-auth.com` tokens whichever host served the
 * session, so this keeps the earlier resolution and default; local token
 * verification depends on it matching exactly.
 */
export function stackTokenIssuerBaseURL(): string {
  const configured =
    process.env.STACK_API_BASE_URL?.trim() ||
    process.env.NEXT_PUBLIC_SERVER_STACK_API_URL?.trim() ||
    process.env.NEXT_PUBLIC_STACK_API_URL?.trim() ||
    process.env.STACK_API_URL?.trim() ||
    "https://api.stack-auth.com";
  return validatedOrigin(configured);
}

function firstConfigured(names: readonly string[]): string | undefined {
  for (const name of names) {
    const value = process.env[name]?.trim();
    if (value) return value;
  }
  return undefined;
}

function validatedOrigin(configuredBaseURL: string): string {
  let parsedBaseURL: URL;
  try {
    parsedBaseURL = new URL(configuredBaseURL);
  } catch {
    throw new Error("Stack Auth API URL is invalid");
  }
  if (
    parsedBaseURL.protocol !== "https:" ||
    !parsedBaseURL.hostname ||
    parsedBaseURL.username ||
    parsedBaseURL.password ||
    parsedBaseURL.search ||
    parsedBaseURL.hash
  ) {
    throw new Error("Stack Auth API URL must use HTTPS");
  }
  return parsedBaseURL.toString().replace(/\/+$/u, "");
}
