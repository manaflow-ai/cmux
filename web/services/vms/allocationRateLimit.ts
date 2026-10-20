import { checkRateLimit } from "@vercel/firewall";
import { reportMissingRateLimitRule } from "../rateLimitObservability";
import { vmErrorResponse } from "./routeHelpers";

const VM_ALLOCATION_RETRY_AFTER_SECONDS = 60;

export type VmAllocationRateLimitCheck = (
  id: string,
  options: { request: Request; rateLimitKey?: string },
) => Promise<{ rateLimited: boolean; error?: string | null }>;

/**
 * Throttle provider-costing VM mutations by their billing scope. Deployed
 * routes fail closed when the Vercel rule is absent or unavailable; local
 * development has no Vercel firewall and remains usable.
 */
export async function enforceVmAllocationRateLimit(input: {
  readonly request: Request;
  readonly route: string;
  readonly billingTeamId: string;
  readonly ruleId?: string | undefined;
  readonly check?: VmAllocationRateLimitCheck;
  readonly isVercel?: boolean;
}): Promise<Response | null> {
  if (!(input.isVercel ?? process.env.VERCEL === "1")) return null;
  const ruleId = (input.ruleId ?? process.env.CMUX_VM_ALLOCATION_RATE_LIMIT_ID)?.trim();
  if (!ruleId) {
    void reportMissingRateLimitRule({ route: input.route, reason: "unset" });
    return unavailableResponse();
  }

  let result: { rateLimited: boolean; error?: string | null };
  try {
    result = await (input.check ?? checkRateLimit)(ruleId, {
      request: input.request,
      rateLimitKey: `vm-allocation:${input.billingTeamId}`,
    });
  } catch {
    console.error("vm allocation rate-limit unavailable", {
      route: input.route,
      failure: "check_failed",
    });
    return unavailableResponse();
  }

  if (result.rateLimited || result.error === "blocked") {
    return vmErrorResponse({
      error: "vm_allocation_rate_limited",
      status: 429,
      message: "Too many Cloud VM allocation requests.",
      action: "Wait a minute, then retry with the same idempotency key.",
      phase: "create",
      retryable: true,
      retryAfterSeconds: VM_ALLOCATION_RETRY_AFTER_SECONDS,
    });
  }
  if (result.error === "not-found") {
    void reportMissingRateLimitRule({ route: input.route, reason: "not-found" });
    return unavailableResponse();
  }
  if (result.error) {
    console.error("vm allocation rate-limit returned an error", {
      route: input.route,
      failure: "check_error",
    });
    return unavailableResponse();
  }
  return null;
}

function unavailableResponse(): Response {
  return vmErrorResponse({
    error: "rate_limit_unavailable",
    status: 503,
    message: "Cloud VM allocation rate limiting is unavailable.",
    action: "Retry in a minute.",
    phase: "create",
    retryable: true,
    retryAfterSeconds: VM_ALLOCATION_RETRY_AFTER_SECONDS,
  });
}
