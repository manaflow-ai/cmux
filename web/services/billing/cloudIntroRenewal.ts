import { and, eq, gt, isNotNull, isNull, lte, sql } from "drizzle-orm";
import type Stripe from "stripe";

import { cloudDb } from "../../db/client";
import { cloudIntroPasses as passes } from "../../db/schema";
import { CLOUD_INTRO_CHECKOUT_PURPOSE, isCloudIntroRenewChargeEnabled } from "./cloudIntro";
import { CLOUD_ENTRY_OFFER_LOCK_KEY } from "./cloudIntroPasses";
import { cloudIntroRenewalChargeAt, type CloudIntroRenewalStatus } from "./cloudIntroStatements";
import { GO_PLAN_ID } from "./pro";

/**
 * The later Plus charge for $1 pass buyers who ticked "continue on Plus"
 * (RFD 0052). At the start of day 30, a granted pass with the choice on and a
 * saved card gets a monthly Plus subscription on its saved customer and card,
 * off-session, behind CMUX_CLOUD_INTRO_RENEW_CHARGE=1.
 *
 * Exactly once per pass: the attempt is claimed (`started`) under the pass
 * lock before the charge, and the charge carries an idempotency key made from
 * the pass id. A failure or a card that needs the buyer's action is recorded
 * and never retried; the pass ends as usual and the day-30 statement asks
 * Plus, Pro or not now. An outcome that could not be read is `unknown` and is
 * never retried either. Someone with a personal plan already is not charged.
 */
export type CloudIntroRenewalStripe = {
  readonly subscriptions: Pick<Stripe["subscriptions"], "create">;
};

export type CloudIntroRenewalCandidate = {
  readonly checkoutSessionId: string;
  readonly stackUserId: string;
  readonly stripeCustomerId: string;
  readonly paymentMethodId: string;
};

export type CloudIntroRenewalOutcome = {
  readonly status: Exclude<CloudIntroRenewalStatus, "started">;
  readonly subscriptionId?: string | null;
  readonly errorCode?: string | null;
};

export type CloudIntroRenewalStore = {
  /** Passes on day 30 with the choice on, a saved card and no attempt yet. */
  listDue(now: Date): Promise<readonly CloudIntroRenewalCandidate[]>;
  /** Records `started` under the lock if the pass is still due; null when it is not. */
  claim(checkoutSessionId: string, now: Date): Promise<CloudIntroRenewalCandidate | null>;
  record(checkoutSessionId: string, outcome: CloudIntroRenewalOutcome): Promise<void>;
};

export type CloudIntroRenewalDependencies = {
  readonly env: Record<string, string | undefined>;
  readonly now: Date;
  readonly store: CloudIntroRenewalStore;
  readonly stripe: () => CloudIntroRenewalStripe;
  readonly plusPriceId: () => Promise<string>;
  /** The buyer already has a personal plan (web or App Store); then nothing is charged. */
  readonly hasPersonalPlan: (stackUserId: string) => Promise<boolean>;
};

export type CloudIntroRenewalResult = {
  readonly skipped: boolean;
  readonly considered: number;
  readonly succeeded: number;
  readonly failed: number;
  readonly requiresAction: number;
  readonly unknown: number;
  readonly hadPlan: number;
};

export function cloudIntroRenewalIdempotencyKey(checkoutSessionId: string): string {
  return `cmux-cloud-intro-renew-${checkoutSessionId}`;
}

/** The pass row facts that make a charge due at `now`. */
export function cloudIntroRenewalDue(
  pass: {
    readonly status: string;
    readonly renewOnPlus: boolean;
    readonly paymentMethodId: string | null;
    readonly stripeCustomerId: string | null;
    readonly renewalStatus: string | null;
    readonly startedAt: Date | null;
    readonly endsAt: Date | null;
  },
  now: Date,
): boolean {
  if (pass.status !== "granted" || !pass.renewOnPlus || !pass.paymentMethodId || !pass.stripeCustomerId) return false;
  if (pass.renewalStatus !== null || !pass.startedAt || !pass.endsAt) return false;
  return cloudIntroRenewalChargeAt(pass.startedAt).getTime() <= now.getTime() && now.getTime() < pass.endsAt.getTime();
}

/** A created subscription, or the error the create threw, as the outcome recorded on the pass. */
export function cloudIntroRenewalOutcome(
  result: { readonly subscription: Pick<Stripe.Subscription, "id" | "status"> } | { readonly error: unknown },
): CloudIntroRenewalOutcome {
  if ("subscription" in result) {
    const { id, status } = result.subscription;
    if (status === "active" || status === "trialing") return { status: "succeeded", subscriptionId: id };
    if (status === "incomplete") return { status: "requires_action", subscriptionId: id, errorCode: "incomplete" };
    return { status: "failed", subscriptionId: id, errorCode: `subscription_${status}` };
  }
  return cloudIntroRenewalErrorOutcome(result.error);
}

type RenewalError = {
  readonly type?: unknown;
  readonly code?: unknown;
  readonly decline_code?: unknown;
  readonly payment_intent?: { readonly status?: unknown } | null;
  readonly raw?: { readonly payment_intent?: { readonly status?: unknown } | null } | null;
};

function stringField(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function paymentIntentStatus(error: RenewalError | null): unknown {
  return error?.payment_intent?.status ?? error?.raw?.payment_intent?.status;
}

function cloudIntroRenewalErrorOutcome(thrown: unknown): CloudIntroRenewalOutcome {
  const error = (thrown ?? null) as RenewalError | null;
  const type = stringField(error?.type) ?? "";
  const code = stringField(error?.code);
  const intentStatus = paymentIntentStatus(error);
  if (code === "authentication_required" || intentStatus === "requires_action") {
    return { status: "requires_action", errorCode: code ?? "requires_action" };
  }
  // A request the payment processor answered and refused; anything else (a timeout, a
  // dropped connection, a server error) leaves the outcome unknown.
  if (type === "StripeCardError" || type === "StripeInvalidRequestError") {
    return { status: "failed", errorCode: stringField(error?.decline_code) ?? code ?? type };
  }
  return { status: "unknown", errorCode: code ?? (type || "error") };
}

export async function runCloudIntroRenewals(deps: CloudIntroRenewalDependencies): Promise<CloudIntroRenewalResult> {
  const result = { skipped: false, considered: 0, succeeded: 0, failed: 0, requiresAction: 0, unknown: 0, hadPlan: 0 };
  if (!isCloudIntroRenewChargeEnabled(deps.env)) return { ...result, skipped: true };
  const due = await deps.store.listDue(deps.now);
  result.considered = due.length;
  for (const candidate of due) {
    const outcome = await renewPass(candidate, deps);
    if (!outcome) continue;
    if (outcome.status === "succeeded") result.succeeded += 1;
    else if (outcome.status === "failed") result.failed += 1;
    else if (outcome.status === "requires_action") result.requiresAction += 1;
    else if (outcome.status === "unknown") result.unknown += 1;
    else result.hadPlan += 1;
  }
  return result;
}

async function renewPass(
  candidate: CloudIntroRenewalCandidate,
  deps: CloudIntroRenewalDependencies,
): Promise<CloudIntroRenewalOutcome | null> {
  // Checked before the claim: a read that fails leaves the pass unclaimed for the next run.
  let hasPlan: boolean;
  let price: string;
  try {
    [hasPlan, price] = await Promise.all([deps.hasPersonalPlan(candidate.stackUserId), deps.plusPriceId()]);
  } catch (error) {
    console.warn("[billing] cmux Cloud pass renewal deferred", {
      checkoutSessionId: candidate.checkoutSessionId,
      error: error instanceof Error ? error.message : String(error),
    });
    return null;
  }
  const claimed = await deps.store.claim(candidate.checkoutSessionId, deps.now);
  if (!claimed) return null;
  if (hasPlan) {
    const outcome: CloudIntroRenewalOutcome = { status: "skipped_has_plan" };
    await deps.store.record(claimed.checkoutSessionId, outcome);
    return outcome;
  }
  let outcome: CloudIntroRenewalOutcome;
  try {
    const subscription = await deps.stripe().subscriptions.create(
      {
        customer: claimed.stripeCustomerId,
        items: [{ price, quantity: 1 }],
        default_payment_method: claimed.paymentMethodId,
        off_session: true,
        payment_behavior: "error_if_incomplete",
        metadata: {
          app: "cmux",
          stackUserId: claimed.stackUserId,
          plan: GO_PLAN_ID,
          billingInterval: "month",
          purpose: `${CLOUD_INTRO_CHECKOUT_PURPOSE}_renewal`,
          cloudIntroCheckoutSessionId: claimed.checkoutSessionId,
        },
      },
      { idempotencyKey: cloudIntroRenewalIdempotencyKey(claimed.checkoutSessionId) },
    );
    outcome = cloudIntroRenewalOutcome({ subscription });
  } catch (error) {
    outcome = cloudIntroRenewalOutcome({ error });
  }
  await deps.store.record(claimed.checkoutSessionId, outcome);
  return outcome;
}

const DAY_MS = 24 * 60 * 60 * 1000;

export function createDrizzleCloudIntroRenewalStore(
  db: () => ReturnType<typeof cloudDb> = cloudDb,
): CloudIntroRenewalStore {
  return {
    async listDue(now) {
      const rows = await db()
        .select()
        .from(passes)
        .where(and(
          eq(passes.status, "granted"),
          eq(passes.renewOnPlus, true),
          isNotNull(passes.paymentMethodId),
          isNotNull(passes.stripeCustomerId),
          isNull(passes.renewalStatus),
          lte(passes.startedAt, new Date(now.getTime() - 29 * DAY_MS)),
          gt(passes.endsAt, now),
        ))
        .limit(200);
      return rows.filter((row) => cloudIntroRenewalDue(row, now)).map(candidateFromRow);
    },

    async claim(checkoutSessionId, now) {
      return await db().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${CLOUD_ENTRY_OFFER_LOCK_KEY}, 0))`);
        const [row] = await tx.select().from(passes).where(eq(passes.checkoutSessionId, checkoutSessionId)).for("update");
        if (!row || !cloudIntroRenewalDue(row, now)) return null;
        await tx
          .update(passes)
          .set({ renewalStatus: "started", renewalAttemptedAt: now, updatedAt: sql`now()` })
          .where(eq(passes.checkoutSessionId, checkoutSessionId));
        return candidateFromRow(row);
      });
    },

    async record(checkoutSessionId, outcome) {
      await db()
        .update(passes)
        .set({
          renewalStatus: outcome.status,
          renewalSubscriptionId: outcome.subscriptionId ?? null,
          renewalErrorCode: outcome.errorCode ?? null,
          updatedAt: sql`now()`,
        })
        .where(and(eq(passes.checkoutSessionId, checkoutSessionId), eq(passes.renewalStatus, "started")));
    },
  };
}

function candidateFromRow(row: typeof passes.$inferSelect): CloudIntroRenewalCandidate {
  return {
    checkoutSessionId: row.checkoutSessionId,
    stackUserId: row.stackUserId,
    stripeCustomerId: row.stripeCustomerId!,
    paymentMethodId: row.paymentMethodId!,
  };
}

/**
 * Turning the later Plus charge off: the choice goes off and the saved card
 * id is cleared under the pass lock, then the card is detached from the
 * customer. Too late once a charge went through or may have.
 */
export type CloudIntroRenewTurnOff =
  | { readonly status: "off"; readonly paymentMethodId: string | null }
  | { readonly status: "already_off" }
  | { readonly status: "too_late" }
  | { readonly status: "no_pass" };

export type CloudIntroRenewTurnOffStore = {
  turnOff(stackUserId: string, now: Date): Promise<CloudIntroRenewTurnOff>;
};

export function createDrizzleCloudIntroRenewTurnOffStore(
  db: () => ReturnType<typeof cloudDb> = cloudDb,
): CloudIntroRenewTurnOffStore {
  return {
    async turnOff(stackUserId, now) {
      return await db().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${CLOUD_ENTRY_OFFER_LOCK_KEY}, 0))`);
        const [row] = await tx
          .select()
          .from(passes)
          .where(and(eq(passes.stackUserId, stackUserId), eq(passes.status, "granted")))
          .for("update");
        return await turnOffRow(row ?? null, now, async (paymentMethodId) => {
          await tx
            .update(passes)
            .set({ renewOnPlus: false, paymentMethodId: null, renewTurnedOffAt: now, updatedAt: sql`now()` })
            .where(eq(passes.checkoutSessionId, row!.checkoutSessionId));
          return paymentMethodId;
        });
      });
    },
  };
}

/** The turn-off decision on one locked row; `write` clears the choice and the card. */
export async function turnOffRow(
  row: {
    readonly renewOnPlus: boolean;
    readonly paymentMethodId: string | null;
    readonly renewalStatus: string | null;
  } | null,
  _now: Date,
  write: (paymentMethodId: string | null) => Promise<string | null>,
): Promise<CloudIntroRenewTurnOff> {
  if (!row) return { status: "no_pass" };
  // A charge in flight, made, or of unknown outcome cannot be taken back here; after a
  // failed charge the card can still be removed.
  if (row.renewalStatus === "started" || row.renewalStatus === "succeeded" || row.renewalStatus === "unknown") {
    return { status: "too_late" };
  }
  if (!row.renewOnPlus && !row.paymentMethodId) return { status: "already_off" };
  return { status: "off", paymentMethodId: await write(row.paymentMethodId) };
}
