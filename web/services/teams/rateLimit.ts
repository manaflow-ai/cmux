import { checkRateLimit } from "@vercel/firewall";
import { reportMissingRateLimitRule } from "../rateLimitObservability";
import { teamErrorResponse } from "./errors";

const TEAM_INVITE_RETRY_AFTER_SECONDS = 60;

export type TeamRateLimitCheck = (
  id: string,
  options: { request: Request; rateLimitKey?: string },
) => Promise<{ rateLimited: boolean; error?: string | null }>;

/**
 * Throttle invite, invite-link, create, join, and accept per signed-in user.
 * Invites send email through Stack, so an unavailable firewall fails closed;
 * an operator-removed rule fails open and is reported.
 */
export async function enforceTeamRateLimit(input: {
  readonly request: Request;
  readonly route: string;
  readonly userId: string;
  readonly ruleId?: string | undefined;
  readonly check?: TeamRateLimitCheck;
  readonly isVercel?: boolean;
}): Promise<Response | null> {
  if (!(input.isVercel ?? process.env.VERCEL === "1")) return null;
  const ruleId = (input.ruleId ?? process.env.CMUX_TEAM_INVITE_RATE_LIMIT_ID)?.trim();
  if (!ruleId) {
    void reportMissingRateLimitRule({ route: input.route, reason: "unset" });
    return null;
  }
  let result: { rateLimited: boolean; error?: string | null };
  try {
    result = await (input.check ?? checkRateLimit)(ruleId, {
      request: input.request,
      rateLimitKey: `team:${input.userId}`,
    });
  } catch {
    console.error("team rate-limit unavailable", { route: input.route, failure: "check_failed" });
    return teamErrorResponse("rate_limit_unavailable", 503);
  }
  if (result.rateLimited || result.error === "blocked") {
    return teamErrorResponse("rate_limited", 429, {
      headers: { "retry-after": String(TEAM_INVITE_RETRY_AFTER_SECONDS) },
    });
  }
  if (result.error === "not-found") {
    void reportMissingRateLimitRule({ route: input.route, reason: "not-found" });
    return null;
  }
  if (result.error) {
    console.error("team rate-limit returned an error", { route: input.route, failure: "check_error" });
    return teamErrorResponse("rate_limit_unavailable", 503);
  }
  return null;
}
