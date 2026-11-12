import { checkRateLimit } from "@vercel/firewall";
import { reportMissingRateLimitRule } from "../rateLimitObservability";
import { vmErrorResponse } from "./routeHelpers";

const VM_FIREWALL_RETRY_AFTER_SECONDS = 60;

export type VmFirewallRateLimitCheck = (
  id: string,
  options: { request: Request; rateLimitKey?: string },
) => Promise<{ rateLimited: boolean; error?: string | null }>;

/**
 * Throttle firewall rule mutations per signed-in user. Every rule goes to one provider account
 * shared by all cmux users, so an unavailable firewall fails closed; an operator-removed rule
 * (unset id, or "not-found") fails open and is reported, as the other Vercel-firewall limits do.
 */
export async function enforceVmFirewallRateLimit(input: {
  readonly request: Request;
  readonly route: string;
  readonly userId: string;
  readonly ruleId?: string | undefined;
  readonly check?: VmFirewallRateLimitCheck;
  readonly isVercel?: boolean;
}): Promise<Response | null> {
  if (!(input.isVercel ?? process.env.VERCEL === "1")) return null;
  const ruleId = (input.ruleId ?? process.env.CMUX_VM_FIREWALL_RATE_LIMIT_ID)?.trim();
  if (!ruleId) {
    void reportMissingRateLimitRule({ route: input.route, reason: "unset" });
    return null;
  }
  let result: { rateLimited: boolean; error?: string | null };
  try {
    result = await (input.check ?? checkRateLimit)(ruleId, { request: input.request, rateLimitKey: `vm-firewall:${input.userId}` });
  } catch {
    console.error("vm firewall rate-limit unavailable", { route: input.route, failure: "check_failed" });
    return vmErrorResponse({ error: "rate_limit_unavailable", status: 503, message: "Rate limiting is unavailable.", action: "Retry in a minute." });
  }
  if (result.rateLimited || result.error === "blocked") {
    return vmErrorResponse({
      error: "vm_rate_limited",
      status: 429,
      message: "Too many firewall changes.",
      action: "Wait a minute, then retry.",
      retryAfterSeconds: VM_FIREWALL_RETRY_AFTER_SECONDS,
    });
  }
  if (result.error === "not-found") {
    void reportMissingRateLimitRule({ route: input.route, reason: "not-found" });
    return null;
  }
  if (result.error) {
    console.error("vm firewall rate-limit returned an error", { route: input.route, failure: "check_error" });
    return vmErrorResponse({ error: "rate_limit_unavailable", status: 503, message: "Rate limiting is unavailable.", action: "Retry in a minute." });
  }
  return null;
}
