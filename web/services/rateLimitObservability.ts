import { reportError } from "./observability/report";

/**
 * Report a Vercel firewall rule that is absent in production.
 *
 * An unset rule is a supported local and preview configuration. In production
 * it removes an abuse-control boundary, so keep the request fail-open for
 * compatibility while making the operator fault visible in Sentry and logs.
 */
export function reportMissingRateLimitRule(input: {
  readonly route: string;
  readonly reason: "unset" | "not-found";
}): void {
  if (process.env.VERCEL_ENV !== "production") return;

  reportError(
    new Error("Vercel firewall rate-limit rule is missing"),
    {
      subsystem: "rate_limit",
      route: input.route,
      reason: input.reason,
    },
    {
      level: "warning",
      fingerprint: ["cmux-rate-limit-rule-missing", input.route],
      tags: {
        subsystem: "rate_limit",
        route: input.route,
        reason: input.reason,
      },
    },
  );
}
