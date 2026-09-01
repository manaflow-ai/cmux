import { eq, sql } from "drizzle-orm";
import { Resend } from "resend";

import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { billingDunningDeliveries } from "../../db/schema";
import { loadMessages } from "../../i18n/messages";
import type { Locale } from "../../i18n/routing";
import { captureBillingDunningDeliveryAbandoned } from "../analytics/stripeBilling";
import { reportError } from "../observability/report";

export const DEFAULT_DUNNING_FROM_EMAIL = "pro@cmux.com";
export const DUNNING_REPLY_TO_EMAIL = "pro@cmux.com";

// Keep concurrent workers from sharing a provider call. Stripe retries that
// arrive during this lease must remain retryable instead of acknowledging the
// webhook, and a later retry can reclaim the row safely with Resend's key.
const DELIVERY_ATTEMPT_LEASE_MS = 15 * 60 * 1000;
// Resend retains idempotency keys for 24 hours. Stop ambiguous retries one
// hour earlier so a late webhook cannot create a duplicate message after the
// provider's idempotency window expires.
const AMBIGUOUS_RETRY_WINDOW_MS = 23 * 60 * 60 * 1000;

export type BillingDunningScope =
  | { readonly scope: "user"; readonly stackUserId: string }
  | { readonly scope: "team"; readonly stackTeamId: string };

export type BillingDunningDeliveryInput = {
  readonly invoiceId: string;
  readonly email: string;
  readonly scope: BillingDunningScope;
};

export type BillingDunningDeliveryResult =
  | "sent"
  | "already_sent"
  | "delivery_in_progress"
  | "delivery_abandoned";

export type BillingDunningAbandonedSignal = {
  readonly invoiceId: string;
  readonly scope: BillingDunningScope;
};

export type BillingDunningAbandonedReporter = (
  input: BillingDunningAbandonedSignal,
) => Promise<void>;

export type BillingDunningDeliveryStore = {
  deliverOnce(
    input: BillingDunningDeliveryInput,
    deliver: () => Promise<void>,
  ): Promise<BillingDunningDeliveryResult>;
  /**
   * Atomically claim the one operator report for a terminally abandoned
   * delivery. The production store implements this against Postgres; the
   * optional shape keeps older test doubles source-compatible.
   */
  claimAbandonedReport?: (
    input: BillingDunningAbandonedSignal,
  ) => Promise<boolean>;
};

export type BillingDunningEmailInput = {
  readonly invoiceId: string;
  readonly email: string | null | undefined;
  readonly customerName?: string | null;
  readonly portalUrl: string;
  readonly scope: BillingDunningScope;
  readonly locale?: Locale;
};

export type BillingDunningEmail = {
  readonly from: string;
  readonly to: string[];
  readonly replyTo: string;
  readonly subject: string;
  readonly text: string;
  readonly html: string;
  readonly headers: Record<string, string>;
};

export type BillingDunningDependencies = {
  readonly sendEmail?: (
    payload: BillingDunningEmail,
    options: { readonly idempotencyKey: string },
  ) => Promise<{ readonly error: unknown | null }>;
  readonly fromEmail?: () => string;
  readonly deliveryStore?: BillingDunningDeliveryStore;
  readonly reportAbandoned?: BillingDunningAbandonedReporter;
};

/** A provider response that proves Resend rejected the message. */
export class BillingDunningProviderRejectedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BillingDunningProviderRejectedError";
  }
}

/** A provider attempt is still ambiguous and Stripe must retry the webhook. */
export class BillingDunningDeliveryRetryableError extends Error {
  constructor(invoiceId: string) {
    super(`cmux billing dunning delivery is still in progress: ${invoiceId}`);
    this.name = "BillingDunningDeliveryRetryableError";
  }
}

/** The provider idempotency window ended without a confirmed delivery. */
export class BillingDunningDeliveryAbandonedError extends Error {
  constructor(invoiceId: string) {
    super(`cmux billing dunning delivery abandoned: ${invoiceId}`);
    this.name = "BillingDunningDeliveryAbandonedError";
  }
}

// Keep the complete Drizzle database type here. Picking only `transaction`
// loses the schema generic on the transaction client and makes inserts infer
// an empty value shape under TypeScript.
type DeliveryDb = ReturnType<typeof cloudDb>;

const defaultDependencies: Required<
  Pick<BillingDunningDependencies, "sendEmail" | "fromEmail">
> & { readonly reportAbandoned: BillingDunningAbandonedReporter } = {
  sendEmail: async (payload, options) => {
    const resend = new Resend(env.RESEND_API_KEY);
    return resend.emails.send(payload, options);
  },
  fromEmail: () => env.CMUX_PRO_FROM_EMAIL ?? DEFAULT_DUNNING_FROM_EMAIL,
  reportAbandoned: reportBillingDunningDeliveryAbandoned,
};

/**
 * Send the payment-failure notice through the invoice-keyed durable ledger.
 * The webhook can call this more than once; only the first committed delivery
 * claim may call Resend.
 */
export async function sendBillingDunningEmail(
  input: BillingDunningEmailInput,
  dependencies: BillingDunningDependencies = {},
): Promise<
  Exclude<BillingDunningDeliveryResult, "delivery_in_progress"> | "no_customer_email"
> {
  const email = normalizeEmail(input.email);
  if (!email) return "no_customer_email";
  if (!input.invoiceId.trim()) {
    throw new Error("Billing dunning delivery is missing an invoice id");
  }

  const deliveryStore =
    dependencies.deliveryStore ?? makeBillingDunningDeliveryStore();
  const sendEmail = dependencies.sendEmail ?? defaultDependencies.sendEmail;
  const fromEmail = dependencies.fromEmail ?? defaultDependencies.fromEmail;
  const result = await deliveryStore.deliverOnce(
    {
      invoiceId: input.invoiceId,
      email,
      scope: input.scope,
    },
    async () => {
      const payload = await buildBillingDunningEmail({
        from: formatFromAddress(fromEmail()),
        to: email,
        customerName: input.customerName,
        locale: input.locale ?? "en",
        portalUrl: input.portalUrl,
        invoiceId: input.invoiceId,
      });
      const { error } = await sendEmail(payload, {
        idempotencyKey: `billing-dunning/${input.invoiceId}`,
      });
      if (error) {
        throw new BillingDunningProviderRejectedError(
          `cmux billing dunning email failed: ${errorMessage(error)}`,
        );
      }
    },
  );
  if (result === "delivery_in_progress") {
    throw new BillingDunningDeliveryRetryableError(input.invoiceId);
  }
  if (result === "delivery_abandoned") {
    const reportAbandoned =
      dependencies.reportAbandoned ?? defaultDependencies.reportAbandoned;
    const shouldReport = deliveryStore.claimAbandonedReport
      ? await deliveryStore.claimAbandonedReport({
          invoiceId: input.invoiceId,
          scope: input.scope,
        })
      : true;
    if (shouldReport) {
      await reportAbandoned({ invoiceId: input.invoiceId, scope: input.scope });
    }
  }
  return result;
}

/** Emit the terminal operator signal without exposing the recipient address. */
export async function reportBillingDunningDeliveryAbandoned(
  input: BillingDunningAbandonedSignal,
  options: { readonly postHogFetch?: typeof fetch } = {},
): Promise<void> {
  const code = "billing_dunning_delivery_abandoned";
  const error = new BillingDunningDeliveryAbandonedError(input.invoiceId);
  reportError(
    error,
    {
      subsystem: "billing_dunning",
      code,
      invoiceId: input.invoiceId,
      billingScope: input.scope.scope,
      operatorFault: true,
    },
    { fingerprint: ["cmux-billing-dunning", code] },
  );
  await captureBillingDunningDeliveryAbandoned(
    {
      invoiceId: input.invoiceId,
      subject: input.scope.scope === "user"
        ? { scope: "user", stackUserId: input.scope.stackUserId }
        : { scope: "team", stackTeamId: input.scope.stackTeamId },
    },
    options.postHogFetch,
  );
}

/** Build the localized plain-text and HTML notice sent by Resend. */
export async function buildBillingDunningEmail(input: {
  readonly from: string;
  readonly to: string;
  readonly customerName?: string | null;
  readonly locale: Locale;
  readonly portalUrl: string;
  readonly invoiceId: string;
}): Promise<BillingDunningEmail> {
  const catalog = await loadMessages(input.locale) as {
    emails: { billingDunning: BillingDunningCopy };
  };
  const copy = catalog.emails.billingDunning;
  const name = firstName(input.customerName) ?? copy.fallbackName;
  const greeting = copy.greeting.replace("{name}", name);
  const portalLink = copy.portalLink.replace("{url}", input.portalUrl);

  return {
    from: input.from,
    to: [input.to],
    replyTo: DUNNING_REPLY_TO_EMAIL,
    subject: copy.subject,
    text: [
      greeting,
      "",
      copy.body,
      "",
      copy.action,
      "",
      portalLink,
      "",
      copy.signoff,
    ].join("\n"),
    html: [
      `<p>${escapeHtml(greeting)}</p>`,
      `<p>${escapeHtml(copy.body)}</p>`,
      `<p>${escapeHtml(copy.action)}</p>`,
      `<p><a href="${escapeHtml(input.portalUrl)}">${escapeHtml(copy.portalLinkLabel)}</a></p>`,
      `<p>${escapeHtml(copy.signoff).replaceAll("\n", "<br>")}</p>`,
    ].join(""),
    headers: { "X-Entity-Ref-ID": `billing-dunning/${input.invoiceId}` },
  };
}

/** Build the production store. Postgres is the cross-instance authority. */
export function makeBillingDunningDeliveryStore(
  db: DeliveryDb = cloudDb(),
): BillingDunningDeliveryStore {
  return {
    claimAbandonedReport: async (input) =>
      await claimAbandonedDeliveryReport(db, input, new Date()),
    deliverOnce: async (input, deliver) => {
      const claimedAt = new Date();
      const claim = await claimDelivery(db, input, claimedAt);
      if (claim !== "claimed") return claim;

      try {
        // The provider call is outside the transaction. The committed lease
        // fences concurrent workers while keeping a database connection free.
        await deliver();
      } catch (error) {
        if (error instanceof BillingDunningProviderRejectedError) {
          await releaseDeliveryAttempt(db, input, new Date());
        }
        throw error;
      }
      await markDeliverySent(db, input, new Date());
      return "sent";
    },
  };
}

/**
 * Claim the terminal operator report under the same invoice advisory lock as
 * delivery state. Only the transaction that changes a null marker can report.
 */
async function claimAbandonedDeliveryReport(
  db: DeliveryDb,
  input: BillingDunningAbandonedSignal,
  reportedAt: Date,
): Promise<boolean> {
  return await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${dunningLockKey(input.invoiceId)}, 0))`,
    );
    const [existing] = await tx
      .select({
        sentAt: billingDunningDeliveries.sentAt,
        abandonedReportedAt: billingDunningDeliveries.abandonedReportedAt,
      })
      .from(billingDunningDeliveries)
      .where(eq(billingDunningDeliveries.invoiceId, input.invoiceId))
      .limit(1);

    // A successful delivery or a previous report makes this a no-op. The
    // advisory lock makes the read-and-set transition atomic across workers.
    if (!existing || existing.sentAt || existing.abandonedReportedAt) {
      return false;
    }
    await tx
      .update(billingDunningDeliveries)
      .set({
        abandonedReportedAt: reportedAt,
        updatedAt: reportedAt,
      })
      .where(eq(billingDunningDeliveries.invoiceId, input.invoiceId));
    return true;
  });
}

type StoredDunningDelivery = {
  readonly email: string;
  readonly scope: string;
  readonly stackUserId: string | null;
  readonly stackTeamId: string | null;
  readonly deliveryStartedAt: Date | null;
  readonly attemptLeaseExpiresAt: Date | null;
  readonly sentAt: Date | null;
};

async function claimDelivery(
  db: DeliveryDb,
  input: BillingDunningDeliveryInput,
  claimedAt: Date,
): Promise<"claimed" | Exclude<BillingDunningDeliveryResult, "sent">> {
  return await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${dunningLockKey(input.invoiceId)}, 0))`,
    );
    const [existing] = await tx
      .select({
        email: billingDunningDeliveries.email,
        scope: billingDunningDeliveries.scope,
        stackUserId: billingDunningDeliveries.stackUserId,
        stackTeamId: billingDunningDeliveries.stackTeamId,
        deliveryStartedAt: billingDunningDeliveries.deliveryStartedAt,
        attemptLeaseExpiresAt: billingDunningDeliveries.attemptLeaseExpiresAt,
        sentAt: billingDunningDeliveries.sentAt,
      })
      .from(billingDunningDeliveries)
      .where(eq(billingDunningDeliveries.invoiceId, input.invoiceId))
      .limit(1);

    if (existing?.sentAt) return "already_sent";
    if (existing && !sameDeliveryOwner(existing, input)) {
      throw new Error("Billing dunning invoice ownership changed before delivery");
    }
    // A live lease always wins over the terminal deadline. This avoids
    // reporting an abandonment while the original provider call can still
    // finish and mark the row sent.
    if (existing?.attemptLeaseExpiresAt && existing.attemptLeaseExpiresAt > claimedAt) {
      return "delivery_in_progress";
    }
    if (
      existing?.deliveryStartedAt &&
      claimedAt.getTime() - existing.deliveryStartedAt.getTime() >=
        AMBIGUOUS_RETRY_WINDOW_MS
    ) {
      return "delivery_abandoned";
    }

    // Once the short lease expires, a retry can reclaim the row while Resend's
    // invoice-keyed idempotency key remains valid. The original start time is
    // retained so the terminal provider window is still bounded.

    const attemptLeaseExpiresAt = new Date(
      claimedAt.getTime() + DELIVERY_ATTEMPT_LEASE_MS,
    );
    if (!existing) {
      await tx.insert(billingDunningDeliveries).values({
        invoiceId: input.invoiceId,
        email: input.email,
        scope: input.scope.scope,
        stackUserId: input.scope.scope === "user" ? input.scope.stackUserId : null,
        stackTeamId: input.scope.scope === "team" ? input.scope.stackTeamId : null,
        deliveryStartedAt: claimedAt,
        attemptLeaseExpiresAt,
        updatedAt: claimedAt,
      });
    } else {
      await tx
        .update(billingDunningDeliveries)
        .set({
          deliveryStartedAt: existing.deliveryStartedAt ?? claimedAt,
          attemptLeaseExpiresAt,
          updatedAt: claimedAt,
        })
        .where(eq(billingDunningDeliveries.invoiceId, input.invoiceId));
    }
    return "claimed";
  });
}

async function releaseDeliveryAttempt(
  db: DeliveryDb,
  input: BillingDunningDeliveryInput,
  releasedAt: Date,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${dunningLockKey(input.invoiceId)}, 0))`,
    );
    await tx
      .update(billingDunningDeliveries)
      .set({
        deliveryStartedAt: null,
        attemptLeaseExpiresAt: null,
        updatedAt: releasedAt,
      })
      .where(eq(billingDunningDeliveries.invoiceId, input.invoiceId));
  });
}

async function markDeliverySent(
  db: DeliveryDb,
  input: BillingDunningDeliveryInput,
  sentAt: Date,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${dunningLockKey(input.invoiceId)}, 0))`,
    );
    await tx
      .update(billingDunningDeliveries)
      .set({
        sentAt,
        attemptLeaseExpiresAt: null,
        updatedAt: sentAt,
      })
      .where(eq(billingDunningDeliveries.invoiceId, input.invoiceId));
  });
}

function sameDeliveryOwner(
  existing: StoredDunningDelivery,
  input: BillingDunningDeliveryInput,
): boolean {
  return existing.email === input.email &&
    existing.scope === input.scope.scope &&
    (input.scope.scope === "user"
      ? existing.stackUserId === input.scope.stackUserId && existing.stackTeamId === null
      : existing.stackTeamId === input.scope.stackTeamId && existing.stackUserId === null);
}

function dunningLockKey(invoiceId: string): string {
  return `billing-dunning:${invoiceId}`;
}

type BillingDunningCopy = {
  readonly subject: string;
  readonly fallbackName: string;
  readonly greeting: string;
  readonly body: string;
  readonly action: string;
  readonly portalLink: string;
  readonly portalLinkLabel: string;
  readonly signoff: string;
};

function normalizeEmail(email: string | null | undefined): string | null {
  const normalized = email?.trim().toLowerCase();
  return normalized && normalized.includes("@") ? normalized : null;
}

function firstName(name: string | null | undefined): string | null {
  return name?.trim().split(/\s+/)[0] || null;
}

function formatFromAddress(email: string): string {
  return `cmux Billing <${email}>`;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (
    error &&
    typeof error === "object" &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return String(error);
}
