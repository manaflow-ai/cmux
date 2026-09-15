import { createHash } from "node:crypto";

type RateLimitResult = {
  readonly rateLimited: boolean;
  readonly error?: "not-found" | "blocked";
};

const FIREWALL_TIMEOUT_MS = 1_000;

/**
 * The @vercel/firewall helper does not accept an AbortSignal. Client config
 * runs on the app boot path, so use the same protocol with a bounded request
 * that cannot leave an unresolved Firewall operation behind a timed-out load.
 */
export async function checkAbortableRateLimit(
  rateLimitId: string,
  request: Request,
  rateLimitKey: string,
): Promise<RateLimitResult> {
  const requestHeaders = request.headers;
  const firewallHost = requestHeaders.get("host");
  if (!firewallHost) throw new Error("Missing request host for Vercel Firewall");

  let pathPrefix = process.env.PUBLIC_VERCEL_FIREWALL_PATH_PREFIX ??
    process.env.NEXT_PUBLIC_VERCEL_FIREWALL_PATH_PREFIX ?? "";
  if (pathPrefix && !pathPrefix.startsWith("/")) pathPrefix = `/${pathPrefix}`;

  const fullRateLimitKey = `${rateLimitKey}-${await hashString(
    rateLimitKey + rateLimitId +
      (process.env.VERCEL_AUTOMATION_BYPASS_SECRET ?? "") +
      (process.env.RATE_LIMIT_SECRET ?? ""),
  )}`;
  const rateLimitHeaders = new Headers({
    "x-vercel-rate-limit-api": rateLimitId,
    "x-vercel-rate-limit-key": fullRateLimitKey,
    "user-agent": "Bot/Vercel Rate Limit Checker",
    "x-forwarded-for": requestHeaders.get("x-forwarded-for") ?? "",
    "x-real-ip": requestHeaders.get("x-real-ip") ?? "",
    "x-vercel-protection-bypass": process.env.VERCEL_AUTOMATION_BYPASS_SECRET ?? "",
  });
  const vercelJwt = parseCookie(requestHeaders.get("cookie"), "_vercel_jwt");
  if (vercelJwt) rateLimitHeaders.set("cookie", `_vercel_jwt=${vercelJwt}`);
  for (const [key, value] of requestHeaders.entries()) {
    rateLimitHeaders.append(`x-rr-${key}`, value);
  }

  const response = await fetch(
    `https://${firewallHost}${pathPrefix}/.well-known/vercel/rate-limit-api/${encodeURIComponent(rateLimitId)}`,
    {
      method: "GET",
      headers: rateLimitHeaders,
      redirect: "manual",
      signal: AbortSignal.timeout(FIREWALL_TIMEOUT_MS),
    },
  );
  if (response.status === 204) return { rateLimited: false };
  if (response.status === 429) return { rateLimited: true };
  if (response.status === 403) return { rateLimited: true, error: "blocked" };
  if (response.status === 404) return { rateLimited: false, error: "not-found" };
  throw new Error(`Unexpected rate-limit API response status '${rateLimitId}': ${response.status}`);
}

async function hashString(input: string): Promise<string> {
  // node:crypto is available in the Node runtime used by this route and keeps
  // the helper independent from a global crypto implementation in tests.
  return createHash("sha256").update(input).digest("hex");
}

function parseCookie(cookieHeader: string | null, name: string): string | undefined {
  if (!cookieHeader) return undefined;
  for (const cookie of cookieHeader.split(";")) {
    const trimmed = cookie.trim();
    const separator = trimmed.indexOf("=");
    if (separator !== -1 && trimmed.slice(0, separator) === name) {
      return trimmed.slice(separator + 1);
    }
  }
  return undefined;
}
