// Who is paged for a terminal coderouter outcome. Shared by the request
// finalizer (PostHog exception level) and the ledger alert cron, so an
// outcome that files an `error` issue is the same outcome the cron counts.

export type CoderouterOutcome = {
  readonly outcome: string;
  readonly failureStage: string;
  readonly status: number;
  readonly provider?: string;
  readonly agent?: string;
  readonly attempts?: number;
  readonly refreshRetries?: number;
  /** Time spent waiting for upstream capacity before the answer. */
  readonly heldMs?: number;
  readonly holdCount?: number;
  readonly upstreamKind?: string;
  readonly upstreamAccountId?: string;
  readonly responseStreamed?: boolean;
};

export type CoderouterFault = "none" | "caller" | "tenant" | "upstream" | "operator";

/**
 * Whose fault a terminal outcome is. Only `operator` pages anyone: RDS, KMS,
 * config and crashes are ours. `upstream` is a provider outage, rate limit or
 * bad provider catalog we failed over on and still lost. `tenant` is a team
 * with no usable account (none added, all cooling down). `caller` is a bad
 * token or a client error the guest must fix.
 */
export function classifyCoderouterFault(outcome: CoderouterOutcome): CoderouterFault {
  const { status } = outcome;
  if (status < 400) return "none";
  if (outcome.outcome === "client_cancelled") return "caller";
  // A team with no account configured at all gets a terminal 4xx so clients
  // stop retrying; it is still the tenant's state to fix.
  if (outcome.outcome === "no_usable_account" && outcome.failureStage === "provider_config") return "tenant";
  if (outcome.outcome === "unauthorized" || (status < 500 && status !== 429)) return "caller";
  switch (outcome.outcome) {
    case "route_crash":
      return "operator";
    case "provider_unavailable":
      return outcome.failureStage === "upstream_transport" ||
          outcome.failureStage === "upstream_response"
        ? "upstream"
        : "operator";
    case "no_usable_account":
      return outcome.failureStage === "credential_refresh" || outcome.failureStage === "upstream_transport"
        ? "upstream"
        : "tenant";
    case "upstream_error":
      return "upstream";
    case "invalid_provider":
    case "unknown_provider":
      return "upstream";
    default:
      return status >= 500 ? "operator" : "caller";
  }
}
