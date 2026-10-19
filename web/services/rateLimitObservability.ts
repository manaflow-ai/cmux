import { sql } from "drizzle-orm";
import { after } from "next/server";

import { cloudDb } from "../db/client";
import { reportError } from "./observability/report";

const CLAIM_COOLDOWN_MS = 5 * 60 * 1_000;
const MAX_LOCAL_KEYS = 128;

type AlertInput = {
  readonly route: string;
  readonly reason: "unset" | "not-found";
};

type ReporterDependencies = {
  readonly now?: () => number;
  readonly claim?: (key: string) => Promise<"claimed" | "duplicate" | "unavailable">;
  readonly report?: typeof reportError;
};

/** Fleet-wide, bounded reporting for a missing Vercel firewall rule. */
export class RateLimitRuleReporter {
  private readonly now: () => number;
  private readonly claim: (key: string) => Promise<"claimed" | "duplicate" | "unavailable">;
  private readonly report: typeof reportError;
  private readonly inFlight = new Map<string, Promise<void>>();
  private readonly lastClaimAt = new Map<string, number>();

  constructor(dependencies: ReporterDependencies = {}) {
    this.now = dependencies.now ?? Date.now;
    this.claim = dependencies.claim ?? claimAlert;
    this.report = dependencies.report ?? reportError;
  }

  reportMissing(input: AlertInput): void {
    if (process.env.VERCEL_ENV !== "production") return;

    const key = `${input.route}:${input.reason}`;
    const now = this.now();
    const previous = this.lastClaimAt.get(key);
    if (previous !== undefined && now - previous < CLAIM_COOLDOWN_MS) return;
    this.lastClaimAt.set(key, now);
    this.trimLocalState();
    if (this.inFlight.has(key)) return;
    const work = this.run(input, key);
    this.inFlight.set(key, work);
    const finished = work.finally(() => {
      this.inFlight.delete(key);
    });

    try {
      after(() => finished);
    } catch {
      void finished;
    }
  }

  private async run(input: AlertInput, key: string): Promise<void> {
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
  }

  private trimLocalState(): void {
    while (this.lastClaimAt.size > MAX_LOCAL_KEYS) {
      const oldest = this.lastClaimAt.keys().next().value;
      if (oldest === undefined) return;
      this.lastClaimAt.delete(oldest);
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
