import { reportError } from "./observability/report";

const ALERT_COOLDOWN_MS = 5 * 60 * 1_000;
const lastAlertAt = new Map<string, number>();

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

  const key = `${input.route}:${input.reason}`;
  const now = Date.now();
  const previous = lastAlertAt.get(key);
  if (previous !== undefined && now - previous < ALERT_COOLDOWN_MS) return;
  lastAlertAt.set(key, now);

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
