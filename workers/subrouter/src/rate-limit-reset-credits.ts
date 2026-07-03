/**
 * Codex Desktop (ChatGPT) "rate limit reset credits" integration.
 *
 * Reverse-engineered from Codex.app 149.0.7827.115 (2026-06-16):
 *
 *   GET  https://chatgpt.com/backend-api/wham/rate-limit-reset-credits
 *   POST https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume
 *
 * The GET endpoint returns a list of "complimentary session resets" (one-time
 * rate-limit resets) that are available for the authenticated account, plus a
 * count of how many are still redeemable. The POST endpoint redeems a specific
 * credit by id. The Subrouter control plane can proxy these calls so that
 * cmux-managed accounts can be inspected and routed based on reset-credit
 * availability.
 */

export interface RateLimitResetCredit {
  id: string;
  status: string;
  title?: string;
  description?: string;
  profile_user_id?: string;
  profile_image_url?: string;
}

export interface RateLimitResetCredits {
  available_count: number;
  credits: RateLimitResetCredit[];
}

export interface RateLimitResetCreditsResponse {
  rate_limit_reset_credits: RateLimitResetCredits;
}

export interface ConsumeRateLimitResetCreditsRequest {
  credit_id: string;
  redeem_request_id: string;
}

export interface CodexApiError {
  code?: string;
  message?: string;
}

export const RATE_LIMIT_RESET_CREDITS_PATH = "/backend-api/wham/rate-limit-reset-credits";
export const RATE_LIMIT_RESET_CREDITS_CONSUME_PATH =
  "/backend-api/wham/rate-limit-reset-credits/consume";

export function parseConsumeRateLimitResetCreditBody(
  body: unknown,
): ConsumeRateLimitResetCreditsRequest | null {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return null;
  }
  const record = body as Record<string, unknown>;
  const creditID = record["credit_id"];
  const redeemRequestID = record["redeem_request_id"];
  if (typeof creditID !== "string" || typeof redeemRequestID !== "string") {
    return null;
  }
  if (!creditID || !redeemRequestID) {
    return null;
  }
  return {
    credit_id: creditID,
    redeem_request_id: redeemRequestID,
  };
}

function chatgptBackendURL(base: string): string {
  const trimmed = base.trim().replace(/\/+$/u, "");
  if (trimmed.endsWith("/backend-api")) {
    return trimmed;
  }
  if (trimmed.endsWith("/backend-api/codex")) {
    return trimmed.slice(0, -"/codex".length);
  }
  return `${trimmed}/backend-api`;
}

function authHeaders(authToken: string): Record<string, string> {
  const bearer = authToken.match(/^Bearer\s+(.+)$/iu);
  const token = bearer?.[1]?.trim() || authToken;
  return {
    authorization: `Bearer ${token}`,
    "content-type": "application/json",
  };
}

export async function fetchRateLimitResetCredits(
  backendBaseURL: string,
  authToken: string,
  fetcher: typeof fetch = fetch,
): Promise<RateLimitResetCreditsResponse> {
  const url = `${chatgptBackendURL(backendBaseURL)}${RATE_LIMIT_RESET_CREDITS_PATH.slice("/backend-api".length)}`;
  const response = await fetcher(url, {
    method: "GET",
    headers: authHeaders(authToken),
  });
  if (!response.ok) {
    const body = await response.text();
    throw new RateLimitResetCreditsError(
      `fetch failed: ${response.status} ${response.statusText}`,
      response.status,
      body,
    );
  }
  const json = (await response.json()) as RateLimitResetCreditsResponse;
  return json;
}

export async function consumeRateLimitResetCredit(
  backendBaseURL: string,
  authToken: string,
  request: ConsumeRateLimitResetCreditsRequest,
  fetcher: typeof fetch = fetch,
): Promise<unknown> {
  const url = `${chatgptBackendURL(backendBaseURL)}${RATE_LIMIT_RESET_CREDITS_CONSUME_PATH.slice("/backend-api".length)}`;
  const response = await fetcher(url, {
    method: "POST",
    headers: authHeaders(authToken),
    body: JSON.stringify({
      credit_id: request.credit_id,
      redeem_request_id: request.redeem_request_id,
    }),
  });
  if (!response.ok) {
    const body = await response.text();
    throw new RateLimitResetCreditsError(
      `consume failed: ${response.status} ${response.statusText}`,
      response.status,
      body,
    );
  }
  return response.json();
}

export class RateLimitResetCreditsError extends Error {
  constructor(
    message: string,
    public readonly statusCode: number,
    public readonly responseBody: string,
  ) {
    super(message);
    this.name = "RateLimitResetCreditsError";
  }
}
