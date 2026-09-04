import { sql } from "drizzle-orm";

import { cloudDb } from "../db/client";
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
export async function reportMissingRateLimitRule(input: {
  readonly route: string;
  readonly reason: "unset" | "not-found";
}): Promise<void> {
  if (process.env.VERCEL_ENV !== "production") return;

  const key = `${input.route}:${input.reason}`;
  const now = Date.now();
  const previous = lastAlertAt.get(key);
  if (previous !== undefined && now - previous < ALERT_COOLDOWN_MS) return;
  lastAlertAt.set(key, now);

  // The durable ledger deduplicates across all Vercel instances. Keep the
  // statement timeout inside the transaction so an Aurora outage cannot retain
  // a pooled connection after this best-effort report.
  try {
    const rows = await cloudDb().transaction(async (tx) => {
      await tx.execute(sql`set local statement_timeout = '1000ms'`);
      return tx.execute(sql`
        insert into rate_limit_alert_reports (alert_key, reported_at)
        values (${key}, now())
        on conflict (alert_key) do update
          set reported_at = excluded.reported_at
          where rate_limit_alert_reports.reported_at < now() - interval '5 minutes'
        returning alert_key
      `);
    });
    if (!rows[0]) return;
  } catch {
    // Reporting must not make a public endpoint depend on the database. The
    // local cooldown still prevents a hot process from generating a loop.
    return;
  }

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
