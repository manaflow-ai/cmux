import { sql } from "drizzle-orm";
import { after } from "next/server";

import { cloudDb } from "../db/client";
import { reportError } from "./observability/report";

type AlertInput = {
  readonly route: string;
  readonly reason: "unset" | "not-found";
};

type ReporterDependencies = {
  readonly claim?: (key: string) => Promise<"claimed" | "duplicate" | "unavailable">;
  readonly report?: typeof reportError;
};

/** Fleet-wide, bounded reporting for a missing Vercel firewall rule. */
export class RateLimitRuleReporter {
  private readonly claim: (key: string) => Promise<"claimed" | "duplicate" | "unavailable">;
  private readonly report: typeof reportError;

  constructor(dependencies: ReporterDependencies = {}) {
    this.claim = dependencies.claim ?? claimAlert;
    this.report = dependencies.report ?? reportError;
  }

  reportMissing(input: AlertInput): void {
    if (process.env.VERCEL_ENV !== "production") return;

    const key = `${input.route}:${input.reason}`;
    const work = async () => {
      const result = await this.claim(key);
      if (result === "unavailable") {
        console.error("cmux.rate_limit.alert_dedupe_unavailable", {
          route: input.route,
          reason: input.reason,
        });
        return;
      }
      if (result === "duplicate") return;
      this.report(
        new Error("Vercel firewall rate-limit rule is missing"),
        { subsystem: "rate_limit", route: input.route, reason: input.reason },
        {
          level: "warning",
          fingerprint: ["cmux-rate-limit-rule-missing", input.route],
          tags: { subsystem: "rate_limit", route: input.route, reason: input.reason },
        },
      );
    };

    try {
      after(work);
    } catch {
      void work();
    }
  }
}

const defaultReporter = new RateLimitRuleReporter();

export function reportMissingRateLimitRule(input: AlertInput): void {
  defaultReporter.reportMissing(input);
}

async function claimAlert(
  key: string,
): Promise<"claimed" | "duplicate" | "unavailable"> {
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
    return rows[0] ? "claimed" : "duplicate";
  } catch {
    return "unavailable";
  }
}
