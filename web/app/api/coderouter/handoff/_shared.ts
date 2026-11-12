import { checkRateLimit as defaultCheckRateLimit } from "@vercel/firewall";

import { env } from "../../../env";
import {
  isValidCoderouterHandoffLease,
} from "../../../../services/coderouter/repository";
import { parseNativeStackTokens } from "../../../../services/vms/auth";

export const CODEROUTER_HANDOFF_MAX_BODY_BYTES = 2 * 1_024;
export const CODEROUTER_HANDOFF_MAX_AUTH_HEADER_BYTES = 16 * 1_024;
export const CODEROUTER_HANDOFF_TEAM_HEADER_NAMES = [
  "x-cmux-team-id",
  "x-cmux-billing-team-id",
] as const;
export const CODEROUTER_HANDOFF_TEAM_QUERY_NAMES = [
  "teamId",
  "team_id",
  "billingTeamId",
  "billing_team_id",
] as const;
const LOCAL_RATE_LIMIT_WINDOW_MS = 60_000;
const LOCAL_RATE_LIMIT_MAX_REQUESTS = 60;

export type HandoffRateLimitOutcome =
  | "allowed"
  | "limited"
  | "unavailable";

export type HandoffRateLimiter = (
  request: Request,
) => Promise<HandoffRateLimitOutcome>;

type HandoffRateLimiterDependencies = {
  readonly checkRateLimit?: typeof defaultCheckRateLimit;
  readonly isVercel?: () => boolean;
  readonly rateLimitId?: () => string | undefined;
  readonly now?: () => number;
};

type BoundedBody =
  | { readonly ok: true; readonly body: string }
  | { readonly ok: false; readonly status: 400 | 413 };

/**
 * Both handoff methods share one durable rule and one local backstop. The
 * local closure is intentionally shared too, so mint plus exchange cannot
 * each get an independent development budget.
 */
export const defaultCoderouterHandoffRateLimiter: HandoffRateLimiter =
  makeCoderouterHandoffRateLimiter({
    checkRateLimit: defaultCheckRateLimit,
    rateLimitId: configuredHandoffRateLimitId,
  });

/**
 * The durable Vercel firewall is required for deployed exchange traffic. The
 * process-local bucket is only a development/test backstop; it is deliberately
 * global to this process and never trusts caller-supplied forwarding headers.
 */
export function makeCoderouterHandoffRateLimiter(
  dependencies: HandoffRateLimiterDependencies = {},
): HandoffRateLimiter {
  let count = 0;
  let resetAt = 0;
  const isVercel = dependencies.isVercel ?? (() => process.env.VERCEL === "1");
  const now = dependencies.now ?? Date.now;

  return async (request) => {
    if (isVercel()) {
      const rateLimitId = dependencies.rateLimitId?.();
      // A missing durable limiter is an operator/configuration failure, not an
      // invitation to run an unauthenticated bearer exchange without a cap.
      if (!rateLimitId) return "unavailable";
      try {
        const result = await (dependencies.checkRateLimit ?? defaultCheckRateLimit)(
          rateLimitId,
          { request },
        );
        if (result.rateLimited || result.error === "blocked") return "limited";
        if (result.error) return "unavailable";
        return "allowed";
      } catch {
        return "unavailable";
      }
    }

    if (process.env.NODE_ENV === "production") return "unavailable";
    const current = now();
    if (current >= resetAt) {
      count = 1;
      resetAt = current + LOCAL_RATE_LIMIT_WINDOW_MS;
      return "allowed";
    }
    count += 1;
    return count > LOCAL_RATE_LIMIT_MAX_REQUESTS ? "limited" : "allowed";
  };
}

export function noStoreHeaders(
  additional: Record<string, string> = {},
): Headers {
  const headers = new Headers({
    "cache-control": "no-store",
    "content-type": "application/json",
    "referrer-policy": "no-referrer",
    ...additional,
  });
  return headers;
}

export function jsonHandoffResponse(
  value: unknown,
  status = 200,
  additionalHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: noStoreHeaders(additionalHeaders),
  });
}

export function rateLimitResponse(
  outcome: HandoffRateLimitOutcome,
): Response | null {
  if (outcome === "allowed") return null;
  if (outcome === "limited") {
    return jsonHandoffResponse(
      { error: "throttled", retryable: true },
      429,
      { "retry-after": "60" },
    );
  }
  return jsonHandoffResponse(
    {
      error: "handoff_unavailable",
      message: "CodeRouter handoff is temporarily unavailable.",
      retryable: true,
    },
    503,
    { "retry-after": "5" },
  );
}

/**
 * Native authorization is the Stack access/refresh pair, not a user-agent or
 * an assertion header. A cookie-only request is intentionally not native.
 */
export function hasNativeStackAuthHeaders(request: Request): boolean {
  return request.headers.get("authorization") !== null ||
    request.headers.get("x-stack-refresh-token") !== null;
}

export function isBoundedNativeStackRequest(request: Request): boolean {
  const authorization = request.headers.get("authorization");
  const refreshToken = request.headers.get("x-stack-refresh-token");
  if (
    authorization === null ||
    refreshToken === null ||
    request.headers.get("cookie") !== null
  ) return false;
  if (
    byteLength(authorization) > CODEROUTER_HANDOFF_MAX_AUTH_HEADER_BYTES ||
    byteLength(refreshToken) > CODEROUTER_HANDOFF_MAX_AUTH_HEADER_BYTES
  ) {
    return false;
  }
  return parseNativeStackTokens(request) !== null;
}

export function validTeamSelectorHeaders(request: Request): boolean {
  const selectors = new Set<string>();
  for (const name of CODEROUTER_HANDOFF_TEAM_HEADER_NAMES) {
    const value = request.headers.get(name);
    if (value === null) continue;
    // Headers.get() joins repeated field values with commas. Split that
    // representation so duplicate or conflicting header occurrences are
    // subject to the same distinct-selector check as query parameters.
    const values = value.includes(",")
      ? value.split(",").map((part) => part.trim())
      : [value];
    for (const selector of values) {
      if (!boundedSelector(selector)) return false;
      selectors.add(selector);
    }
  }
  try {
    const searchParams = new URL(request.url).searchParams;
    const allowedQueryNames: ReadonlySet<string> = new Set(
      CODEROUTER_HANDOFF_TEAM_QUERY_NAMES,
    );
    // Inspect every occurrence. URLSearchParams.get() would silently choose
    // the first value for repeated aliases, allowing a later authorization
    // layer to consume a different selector than the one we validated.
    for (const [name, value] of searchParams) {
      if (!allowedQueryNames.has(name)) return false;
      if (!boundedSelector(value)) return false;
      selectors.add(value);
    }
  } catch {
    return false;
  }
  return selectors.size <= 1;
}

export function hasCoderouterHandoffTeamSelector(request: Request): boolean {
  for (const name of CODEROUTER_HANDOFF_TEAM_HEADER_NAMES) {
    if (request.headers.get(name) !== null) return true;
  }
  try {
    const url = new URL(request.url);
    return CODEROUTER_HANDOFF_TEAM_QUERY_NAMES.some((name) =>
      url.searchParams.has(name)
    );
  } catch {
    return true;
  }
}

export async function readBoundedBody(
  request: Request,
  limit = CODEROUTER_HANDOFF_MAX_BODY_BYTES,
): Promise<BoundedBody> {
  const rawLength = request.headers.get("content-length");
  if (rawLength !== null) {
    if (!/^\d+$/.test(rawLength.trim())) return { ok: false, status: 400 };
    const length = Number(rawLength.trim());
    if (!Number.isSafeInteger(length)) return { ok: false, status: 413 };
    if (length > limit) return { ok: false, status: 413 };
  }

  const reader = request.body?.getReader();
  if (!reader) return { ok: true, body: "" };

  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let body = "";
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        return { ok: false, status: 413 };
      }
      body += decoder.decode(chunk.value, { stream: true });
    }
    return { ok: true, body: body + decoder.decode() };
  } catch {
    return { ok: false, status: 400 };
  }
}

export function parseEmptyHandoffBody(body: string): boolean {
  if (!body.trim()) return true;
  try {
    const value: unknown = JSON.parse(body);
    return isPlainObject(value) && Object.keys(value).length === 0;
  } catch {
    return false;
  }
}

export function isJsonContentType(request: Request): boolean {
  const contentType = request.headers.get("content-type");
  if (contentType === null) return false;
  return contentType.split(";", 1)[0]?.trim().toLowerCase() ===
    "application/json";
}

/**
 * Produces the data-plane origin clients should persist with the route token.
 * Deployed runtimes must use the operator-configured canonical origin; only
 * non-Vercel local development may fall back to the request URL.
 */
export function coderouterOpenaiBaseUrl(
  request: Request,
  configuredOrigin?: string,
): string | null {
  const origin = normalizedCoderouterOrigin(configuredOrigin);
  if (origin) return `${origin}/v1`;
  const localRuntime =
    process.env.VERCEL !== "1" &&
    (process.env.NODE_ENV === "development" ||
      process.env.NODE_ENV === "test");
  if (!localRuntime) {
    return null;
  }
  try {
    const localOrigin = new URL(request.url);
    if (localOrigin.protocol !== "http:" && localOrigin.protocol !== "https:") {
      return null;
    }
    return `${localOrigin.origin}/v1`;
  } catch {
    return null;
  }
}

export function parseHandoffLeaseBody(body: string): string | null {
  if (!body.trim()) return null;
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    return null;
  }
  if (!isPlainObject(value)) return null;
  const keys = Object.keys(value);
  if (keys.length !== 1 || keys[0] !== "lease") return null;
  const lease = value.lease;
  if (
    typeof lease !== "string" ||
    lease.length !== lease.trim().length ||
    !isValidCoderouterHandoffLease(lease)
  ) {
    return null;
  }
  return lease;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return !!value &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype;
}

function boundedSelector(value: string): boolean {
  const trimmed = value.trim();
  return trimmed.length > 0 &&
    trimmed.length <= 200 &&
    trimmed === value &&
    !/[\u0000-\u001f\u007f]/.test(value);
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function configuredHandoffRateLimitId(): string | undefined {
  const dedicated = env.CMUX_APP_SESSION_HANDOFF_RATE_LIMIT_ID;
  if (dedicated) return dedicated;
  const fallback = env.CMUX_FEEDBACK_RATE_LIMIT_ID;
  return fallback || undefined;
}

function normalizedCoderouterOrigin(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (
      (url.protocol !== "https:" && url.protocol !== "http:") ||
      url.username ||
      url.password ||
      url.pathname !== "/" ||
      url.search ||
      url.hash
    ) {
      return null;
    }
    if (
      url.protocol !== "https:" &&
      !["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)
    ) {
      return null;
    }
    return url.origin;
  } catch {
    return null;
  }
}
