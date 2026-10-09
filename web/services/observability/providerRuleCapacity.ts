import type { AlertInput } from "./alerts";

/**
 * Freestyle caps TLS rules per account. Every cmux machine holds at least two
 * (the CodeRouter and reflection aliases), allowlist domains add one each, and
 * any other workload sharing the account draws from the same pool. At the cap
 * a network policy save cannot add a rule, so operators need to hear about it
 * before users do.
 */
export const DEFAULT_FREESTYLE_TLS_RULE_LIMIT = 2000;
export const TLS_RULE_CAPACITY_ALERT_KEY = "provider-tls-rule-capacity";
const WARNING_FRACTION = 0.85;

export type TlsRuleUsage = {
  readonly provider: string;
  readonly count: number;
  readonly limit: number;
};

/** The alert for a provider's TLS rule usage, or null while it has comfortable headroom. */
export function tlsRuleCapacityAlert(usage: TlsRuleUsage): AlertInput | null {
  if (usage.limit <= 0 || usage.count < usage.limit * WARNING_FRACTION) return null;
  const atLimit = usage.count >= usage.limit;
  return {
    key: TLS_RULE_CAPACITY_ALERT_KEY,
    title: atLimit
      ? `Cloud VM ${usage.provider} TLS rule limit reached`
      : `Cloud VM ${usage.provider} TLS rules near the limit`,
    body: [
      `${usage.count} of ${usage.limit} account-wide TLS rules are in use.`,
      atLimit
        ? "Network policy updates that add a domain fail until rules are freed."
        : `Network policy updates will fail at ${usage.limit}.`,
      "Rules die with their VM, so free them by deleting unused VMs on the shared account (dev, staging, and other workloads included) or ask Freestyle to raise the limit.",
    ].join(" "),
    severity: atLimit ? "critical" : "warning",
  };
}

/** The configured account limit; FREESTYLE_TLS_RULE_LIMIT overrides the documented default. */
export function freestyleTlsRuleLimit(env: Record<string, string | undefined>): number {
  const parsed = Number.parseInt(env.FREESTYLE_TLS_RULE_LIMIT ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_FREESTYLE_TLS_RULE_LIMIT;
}

/**
 * Read the account's TLS rule count with one page-of-one list call. Returns
 * null when this deployment has no Freestyle credentials.
 */
export async function readFreestyleTlsRuleUsage(env: Record<string, string | undefined>): Promise<TlsRuleUsage | null> {
  const hasKey = Boolean(env.FREESTYLE_API_KEY?.trim())
    || Boolean(env.FREESTYLE_STACK_ACCESS_TOKEN?.trim() && env.FREESTYLE_TEAM_ID?.trim());
  if (!hasKey) return null;
  const { freestyleClient } = await import("../vms/drivers/freestyle");
  const page = await freestyleClient().tls.rules.list({ limit: 1 });
  return { provider: "freestyle", count: page.totalCount, limit: freestyleTlsRuleLimit(env) };
}
