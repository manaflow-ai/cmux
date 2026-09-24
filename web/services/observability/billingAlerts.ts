import { and, countDistinct, desc, eq, gte, isNotNull, isNull, lt, notExists, sql } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { cloudDb } from "../../db/client";
import { billingEmailVerificationDeliveries, stripeWebhookEvents } from "../../db/schema";
import { sendAlert, type AlertFetch, type AlertInput, type AlertResult } from "./alerts";

/**
 * Billing checks that ride the five-minute alerts cron.
 *
 * Two silent failures on 2026-09-10 motivate these: a paid checkout whose
 * webhook processing threw (`stripe_webhook_events.error`) and 161 purchase
 * sign-in emails Stack refused, both invisible until someone read a table.
 */
export type BillingAlertCheckSummary = {
  readonly triggered: boolean;
  readonly count: number;
};

export type BillingAlertSummary = {
  readonly webhookErrors: BillingAlertCheckSummary;
  readonly unsentPurchaseEmails: BillingAlertCheckSummary;
};

export type WebhookErrorSample = {
  readonly count: number;
  readonly types: readonly string[];
  readonly latest: string | null;
};

const WEBHOOK_ERROR_WINDOW_MS = 60 * 60 * 1_000;
const UNSENT_EMAIL_WINDOW_MS = 24 * 60 * 60 * 1_000;
/** A delivery normally completes within seconds; allow the retry lease to lapse first. */
const UNSENT_EMAIL_GRACE_MS = 15 * 60 * 1_000;

export async function runBillingAlertChecks(options: {
  readonly db?: ReturnType<typeof cloudDb>;
  readonly env?: Record<string, string | undefined>;
  readonly now?: Date;
  readonly fetch?: AlertFetch;
  readonly sendAlert?: (input: AlertInput) => Promise<AlertResult>;
  readonly countWebhookErrors?: (since: Date) => Promise<WebhookErrorSample>;
  readonly countUnsentPurchaseEmails?: (since: Date, olderThan: Date) => Promise<number>;
} = {}): Promise<BillingAlertSummary> {
  const env = options.env ?? process.env;
  const now = options.now ?? new Date();
  const send = options.sendAlert ?? ((input) => sendAlert(input, { fetch: options.fetch, env }));
  const db = () => options.db ?? cloudDb();
  const countErrors = options.countWebhookErrors ?? ((since) => countWebhookErrorsInDb(db(), since));
  const countUnsent =
    options.countUnsentPurchaseEmails ?? ((since, olderThan) => countUnsentPurchaseEmailsInDb(db(), since, olderThan));

  const errors = await countErrors(new Date(now.getTime() - WEBHOOK_ERROR_WINDOW_MS));
  if (errors.count > 0) {
    await send({
      key: "stripe-webhook-errors",
      title: "Stripe webhook processing errors",
      body: [
        `${errors.count} webhook event(s) failed processing in the last hour.`,
        `Types: ${errors.types.length ? errors.types.join(", ") : "unknown"}.`,
        errors.latest ? `Latest error: ${errors.latest}` : "",
        "A paid checkout in this set has no entitlement until it is replayed.",
      ].filter(Boolean).join(" "),
      severity: "critical",
    });
  }

  const unsent = await countUnsent(
    new Date(now.getTime() - UNSENT_EMAIL_WINDOW_MS),
    new Date(now.getTime() - UNSENT_EMAIL_GRACE_MS),
  );
  if (unsent > 0) {
    await send({
      key: "purchase-emails-unsent",
      title: "Purchase sign-in emails not delivered",
      body: `${unsent} purchase email(s) created in the last 24 hours are still unsent after 15 minutes. Rerun the by-email backfill to retry them.`,
      severity: "warning",
    });
  }

  return {
    webhookErrors: { triggered: errors.count > 0, count: errors.count },
    unsentPurchaseEmails: { triggered: unsent > 0, count: unsent },
  };
}

async function countWebhookErrorsInDb(
  db: ReturnType<typeof cloudDb>,
  since: Date,
): Promise<WebhookErrorSample> {
  const rows = await db
    .select({ type: stripeWebhookEvents.type, error: stripeWebhookEvents.error })
    .from(stripeWebhookEvents)
    .where(and(isNotNull(stripeWebhookEvents.error), gte(stripeWebhookEvents.createdAt, since)))
    .orderBy(desc(stripeWebhookEvents.createdAt))
    .limit(50);
  return {
    count: rows.length,
    types: [...new Set(rows.map((row) => row.type))].sort(),
    latest: rows[0]?.error?.slice(0, 200) ?? null,
  };
}

async function countUnsentPurchaseEmailsInDb(
  db: ReturnType<typeof cloudDb>,
  since: Date,
  olderThan: Date,
): Promise<number> {
  // One purchaser can own several delivery rows (one per checkout session);
  // a row only matters when no session ever reached that account's inbox.
  const [row] = await db
    .select({ count: countDistinct(billingEmailVerificationDeliveries.stackUserId) })
    .from(billingEmailVerificationDeliveries)
    .where(and(
      isNull(billingEmailVerificationDeliveries.sentAt),
      gte(billingEmailVerificationDeliveries.createdAt, since),
      lt(billingEmailVerificationDeliveries.createdAt, olderThan),
      notExists(
        db
          .select({ one: sql`1` })
          .from(alias(billingEmailVerificationDeliveries, "sent"))
          .where(and(
            eq(sql`"sent"."stack_user_id"`, billingEmailVerificationDeliveries.stackUserId),
            isNotNull(sql`"sent"."sent_at"`),
          )),
      ),
    ));
  return Number(row?.count ?? 0);
}
