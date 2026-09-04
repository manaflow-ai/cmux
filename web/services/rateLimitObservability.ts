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

  // Advisory locks are shared by all PostgreSQL sessions, including sessions
  // owned by different Vercel instances. The winning session keeps this lock
  // until the instance exits, so a fleet-wide cold-start storm emits one event.
  try {
    const query = cloudDb().execute(sql`
      select pg_try_advisory_lock(hashtextextended(${key}, 0)) as acquired
    `) as unknown as Promise<readonly [{ acquired?: boolean }?]>;
    const timeout = new Promise<undefined>((resolve) => {
      setTimeout(() => resolve(undefined), 1_000);
    });
    const rows = await Promise.race([query, timeout]);
    if (!rows || !rows[0]?.acquired) return;
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
