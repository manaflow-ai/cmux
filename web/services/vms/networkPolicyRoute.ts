import {
  CMUX_REQUIRED_DOMAINS,
  DEFAULT_NETWORK_POLICY,
  NETWORK_POLICY_PRESETS,
  NetworkPolicyValidationError,
  parseNetworkPolicy,
  type NetworkPolicy,
} from "./networkPolicy";
import { jsonResponse } from "./routeHelpers";
import type { VmNetworkPolicyView } from "./workflows";

/** The preset catalog every client renders; served so a preset change needs no client update. */
export function networkPolicyCatalog() {
  return {
    presets: NETWORK_POLICY_PRESETS,
    requiredDomains: CMUX_REQUIRED_DOMAINS,
    defaultPolicy: DEFAULT_NETWORK_POLICY,
  };
}

export function networkPolicyResponseBody(view: VmNetworkPolicyView) {
  return {
    ...networkPolicyCatalog(),
    policy: view.policy,
    applied: view.status,
  };
}

export function invalidNetworkPolicyResponse(err: NetworkPolicyValidationError): Response {
  return jsonResponse({ error: "invalid_network_policy", path: err.path, message: err.message }, 400);
}

export function parseNetworkPolicyBody(
  body: unknown,
): { readonly ok: true; readonly policy: NetworkPolicy } | { readonly ok: false; readonly response: Response } {
  try {
    return { ok: true, policy: parseNetworkPolicy(body) };
  } catch (err) {
    if (err instanceof NetworkPolicyValidationError) return { ok: false, response: invalidNetworkPolicyResponse(err) };
    throw err;
  }
}

/**
 * The optional `networkPolicy` on a create. Omitted or plain full Internet
 * keeps the create path identical to before (no extra row write).
 */
export function parseCreateNetworkPolicy(
  value: unknown,
): { readonly ok: true; readonly policy: NetworkPolicy | undefined } | { readonly ok: false; readonly response: Response } {
  if (value === undefined || value === null) return { ok: true, policy: undefined };
  const parsed = parseNetworkPolicyBody(value);
  if (!parsed.ok) return parsed;
  return { ok: true, policy: parsed.policy.mode === "full" ? undefined : parsed.policy };
}
