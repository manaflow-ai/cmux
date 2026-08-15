import { checkRateLimit } from "@vercel/firewall";
import { jsonResponse } from "./vms/routeHelpers";

export type NativeIngressRateLimitCheck = (
  id: string,
  options: { request: Request },
) => Promise<{ rateLimited: boolean; error?: string | null }>;

/**
 * Apply a per-IP firewall gate before native authentication reaches Stack Auth.
 * Native clients can retry or reconnect during lifecycle transitions, so this
 * boundary deliberately fails closed on an unavailable firewall and fails open
 * only when an operator has removed the configured rule.
 */
export async function enforceNativeIngressRateLimit(input: {
  readonly request: Request;
  readonly route: string;
  readonly ruleId: string | undefined;
  readonly check?: NativeIngressRateLimitCheck;
  readonly isVercel?: boolean;
}): Promise<Response | null> {
  if (!(input.isVercel ?? process.env.VERCEL === "1")) return null;
  const ruleId = input.ruleId?.trim();
  if (!ruleId) return null;

  let result: { rateLimited: boolean; error?: string | null };
  try {
    result = await (input.check ?? checkRateLimit)(ruleId, {
      request: input.request,
    });
  } catch {
    console.error("native ingress rate-limit unavailable", {
      route: input.route,
      failure: "check_failed",
    });
    return jsonResponse({ error: "rate_limit_unavailable" }, 503);
  }

  if (result.rateLimited || result.error === "blocked") {
    return jsonResponse({ error: "rate_limited" }, 429);
  }
  if (result.error === "not-found") {
    console.warn("native ingress rate-limit rule not found; failing open", {
      route: input.route,
    });
    return null;
  }
  if (result.error) {
    console.error("native ingress rate-limit returned an error", {
      route: input.route,
      failure: "check_error",
    });
    return jsonResponse({ error: "rate_limit_unavailable" }, 503);
  }
  return null;
}
