/**
 * Stack API origin with no trailing slash, e.g. `https://api.stack-auth.com`.
 * Same precedence the Stack SDK uses; HTTPS only. Shared by the server-key
 * PATCH helper and by local access-token verification (JWKS URL), so a
 * self-hosted Stack origin drives both.
 */
export function stackApiBaseURL(): string {
  const configuredBaseURL =
    process.env.STACK_API_BASE_URL?.trim() ||
    process.env.NEXT_PUBLIC_SERVER_STACK_API_URL?.trim() ||
    process.env.NEXT_PUBLIC_STACK_API_URL?.trim() ||
    process.env.STACK_API_URL?.trim() ||
    "https://api.stack-auth.com";
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
