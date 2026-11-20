import { checkRateLimit } from "@vercel/firewall";
import { reportMissingRateLimitRule } from "../rateLimitObservability";
import { vmErrorResponse } from "./routeHelpers";
import { vmMutationGuardCopy, vmRequestLocale } from "./vmErrorMessages";

const VM_ALLOCATION_RETRY_AFTER_SECONDS = 60;
const VM_ALLOCATION_RATE_LIMIT_TIMEOUT_MS = 1_000;

export type VmAllocationRateLimitCheck = (
  id: string,
  options: { request: Request; rateLimitKey?: string; signal: AbortSignal },
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
  readonly timeoutMs?: number;
  /** Provider allocations this request can launch; each consumes one rate-limit check. */
  readonly cost?: number;
}): Promise<Response | null> {
  if (!(input.isVercel ?? process.env.VERCEL === "1")) return null;
  const ruleId = (input.ruleId ?? process.env.CMUX_VM_ALLOCATION_RATE_LIMIT_ID)?.trim();
  if (!ruleId) {
    void reportMissingRateLimitRule({ route: input.route, reason: "unset" });
    return unavailableResponse(input.request);
  }

  const cost = input.cost ?? 1;
  if (!Number.isSafeInteger(cost) || cost < 1 || cost > 32) {
    console.error("vm allocation rate-limit received an invalid cost", {
      route: input.route,
      failure: "invalid_cost",
    });
    return unavailableResponse(input.request);
  }

  let results: Array<{ rateLimited: boolean; error?: string | null }>;
  try {
    const signal = AbortSignal.timeout(input.timeoutMs ?? VM_ALLOCATION_RATE_LIMIT_TIMEOUT_MS);
    results = await Promise.all(Array.from({ length: cost }, () => (input.check ?? checkRateLimit)(ruleId, {
      request: input.request,
      rateLimitKey: `vm-allocation:${input.billingTeamId}`,
      signal,
    })));
  } catch {
    console.error("vm allocation rate-limit unavailable", {
      route: input.route,
      failure: "check_failed",
    });
    return unavailableResponse(input.request);
  }

  if (results.some((result) => result.rateLimited || result.error === "blocked")) {
    const copy = await vmMutationGuardCopy("allocationUnavailable", vmRequestLocale(input.request));
    return vmErrorResponse({
      error: "vm_allocation_rate_limited",
      status: 429,
      message: copy.message,
      action: copy.action,
      displayTitle: copy.title,
      phase: "create",
      retryable: true,
      retryAfterSeconds: VM_ALLOCATION_RETRY_AFTER_SECONDS,
    });
  }
  if (results.some((result) => result.error === "not-found")) {
    void reportMissingRateLimitRule({ route: input.route, reason: "not-found" });
    return unavailableResponse(input.request);
  }
  if (results.some((result) => result.error)) {
    console.error("vm allocation rate-limit returned an error", {
      route: input.route,
      failure: "check_error",
    });
    return unavailableResponse(input.request);
  }
  return null;
}

async function unavailableResponse(request: Request): Promise<Response> {
  const copy = await vmMutationGuardCopy("allocationUnavailable", vmRequestLocale(request));
  return vmErrorResponse({
    error: "rate_limit_unavailable",
    status: 503,
    message: copy.message,
    action: copy.action,
    displayTitle: copy.title,
    phase: "create",
    retryable: true,
    retryAfterSeconds: VM_ALLOCATION_RETRY_AFTER_SECONDS,
  });
}
