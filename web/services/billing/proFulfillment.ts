import { eq, sql } from "drizzle-orm";
import { Resend } from "resend";
import type Stripe from "stripe";

import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { proWelcomeFulfillments } from "../../db/schema";
import { preferredLocaleFromAcceptLanguage } from "../../i18n/accept-language";
import { loadMessages } from "../../i18n/messages";
import type { Locale } from "../../i18n/routing";
import {
  AccountDeletionMutationBlockedError,
  accountDeletionAdvisoryLockKey,
  assertAccountDeletionUserMutationAllowed,
  withAccountDeletionUserMutation,
} from "../account/deletionLock";

export const DEFAULT_PRO_FROM_EMAIL = "pro@cmux.com";
export const PRO_REPLY_TO_EMAIL = "pro@cmux.com";
export const PRO_TESTFLIGHT_SIGNUP_URL = "https://cmux.com/dashboard/testflight";
const PRO_WELCOME_ATTEMPT_LEASE_MS = 2 * 60 * 1000;
// Resend retains idempotency keys for 24 hours. Stop ambiguous retries one
// hour earlier so a delayed webhook cannot duplicate an accepted email.
const PRO_WELCOME_RETRY_WINDOW_MS = 23 * 60 * 60 * 1000;

type ProWelcomeCopy = {
  subject: string;
  fallbackName: string;
  greeting: string;
  thanks: string;
  cloudStatus: string;
  currentBenefit: string;
  testflightLink: string;
  testflightLinkLabel: string;
  signoff: string;
};

export type ProWelcomeFulfillmentStore = {
  deliverOnce(
    input: {
      readonly checkoutSessionId: string;
      readonly stackUserId: string;
    },
    deliver: () => Promise<void>,
  ): Promise<
    "sent" | "already_sent" | "delivery_abandoned" | "account_deleting"
  >;
};

type ProFulfillmentDependencies = {
  sendEmail: (
    payload: ProWelcomeEmail,
    options: { idempotencyKey: string },
  ) => Promise<{ error: unknown | null }>;
  fromEmail: () => string;
  fulfillmentStore: ProWelcomeFulfillmentStore;
};

const defaultDependencies: ProFulfillmentDependencies = {
  sendEmail: async (payload, options) => {
    const resend = new Resend(env.RESEND_API_KEY);
    return resend.emails.send(payload, options);
  },
  fromEmail: () => env.CMUX_PRO_FROM_EMAIL ?? DEFAULT_PRO_FROM_EMAIL,
  fulfillmentStore: {
    deliverOnce: async (input, deliver) => {
      const db = cloudDb();
      try {
        return await withAccountDeletionUserMutation(
          db,
          input.stackUserId,
          async (mutationLease) => {
            const claimedAt = new Date();
            const claim = await claimProWelcomeDelivery(
              db,
              input,
              claimedAt,
            );
            if (claim === "already_sent") return claim;
            if (claim === "delivery_abandoned") {
              console.warn(
                "cmux Pro welcome skipped after the provider idempotency window",
                { checkoutSessionId: input.checkoutSessionId },
              );
              return claim;
            }

            await mutationLease.refresh();
            try {
              await deliver();
            } catch (error) {
              if (error instanceof ProWelcomeProviderRejectedError) {
                await releaseProWelcomeDeliveryAttempt(db, input);
              }
              throw error;
            }
            await markProWelcomeDeliverySent(db, input, new Date());
            return "sent" as const;
          },
        );
      } catch (error) {
        if (error instanceof AccountDeletionMutationBlockedError) {
          return "account_deleting" as const;
        }
        throw error;
      }
    },
  },
};

export type ProWelcomeEmail = {
  from: string;
  to: string[];
  replyTo: string;
  subject: string;
  text: string;
  html: string;
  headers: Record<string, string>;
};

export async function sendProSignupWelcome(
  input: {
    session: Stripe.Checkout.Session;
    stackUserId: string;
  },
  dependencies: ProFulfillmentDependencies = defaultDependencies,
): Promise<void> {
  const sessionRef = input.session.id;
  await dependencies.fulfillmentStore.deliverOnce(
    {
      checkoutSessionId: sessionRef,
      stackUserId: input.stackUserId,
    },
    async () => {
      const email = checkoutEmail(input.session);
      if (!email) {
        // Stripe cannot repair a permanently absent address by redelivering
        // the webhook. Record the no-op fulfillment once so later events do
        // not retry an impossible delivery forever.
        console.warn(
          "cmux Pro welcome skipped: checkout is missing a customer email",
          { checkoutSessionId: sessionRef },
        );
        return;
      }

      const payload = await buildProWelcomeEmail({
        from: formatFromAddress(dependencies.fromEmail()),
        to: email,
        customerName: checkoutCustomerName(input.session),
        locale: checkoutLocale(input.session),
        sessionRef,
      });
      const { error } = await dependencies.sendEmail(payload, {
        idempotencyKey: `pro-welcome/${sessionRef}`,
      });
      if (error) {
        throw new ProWelcomeProviderRejectedError(
          `cmux Pro welcome email failed: ${errorMessage(error)}`,
        );
      }
    },
  );
}

class ProWelcomeProviderRejectedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProWelcomeProviderRejectedError";
  }
}

class ProWelcomeDeliveryInProgressError extends Error {
  constructor(checkoutSessionId: string) {
    super(`cmux Pro welcome delivery is still in progress: ${checkoutSessionId}`);
    this.name = "ProWelcomeDeliveryInProgressError";
  }
}

type ProWelcomeDeliveryIdentity = {
  readonly checkoutSessionId: string;
  readonly stackUserId: string;
};

async function claimProWelcomeDelivery(
  db: ReturnType<typeof cloudDb>,
  input: ProWelcomeDeliveryIdentity,
  claimedAt: Date,
): Promise<"claimed" | "already_sent" | "delivery_abandoned"> {
  return await db.transaction(async (tx) => {
    await assertAccountDeletionUserMutationAllowed(tx, input.stackUserId);
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${`pro-welcome:${input.checkoutSessionId}`}, 0))`,
    );
    const [existing] = await tx
      .select({
        stackUserId: proWelcomeFulfillments.stackUserId,
        deliveryStartedAt: proWelcomeFulfillments.deliveryStartedAt,
        attemptLeaseExpiresAt:
          proWelcomeFulfillments.attemptLeaseExpiresAt,
        sentAt: proWelcomeFulfillments.sentAt,
      })
      .from(proWelcomeFulfillments)
      .where(
        eq(
          proWelcomeFulfillments.checkoutSessionId,
          input.checkoutSessionId,
        ),
      )
      .limit(1);
    if (existing?.sentAt) return "already_sent";
    if (existing && existing.stackUserId !== input.stackUserId) {
      throw new Error(
        "cmux Pro welcome checkout ownership changed before fulfillment",
      );
    }
    if (
      existing?.deliveryStartedAt &&
      claimedAt.getTime() - existing.deliveryStartedAt.getTime() >=
        PRO_WELCOME_RETRY_WINDOW_MS
    ) {
      return "delivery_abandoned";
    }
    if (
      existing?.attemptLeaseExpiresAt &&
      existing.attemptLeaseExpiresAt > claimedAt
    ) {
      throw new ProWelcomeDeliveryInProgressError(input.checkoutSessionId);
    }

    const attemptLeaseExpiresAt = new Date(
      claimedAt.getTime() + PRO_WELCOME_ATTEMPT_LEASE_MS,
    );
    if (!existing) {
      await tx.insert(proWelcomeFulfillments).values({
        checkoutSessionId: input.checkoutSessionId,
        stackUserId: input.stackUserId,
        deliveryStartedAt: claimedAt,
        attemptLeaseExpiresAt,
        updatedAt: claimedAt,
      });
    } else {
      await tx
        .update(proWelcomeFulfillments)
        .set({
          deliveryStartedAt: existing.deliveryStartedAt ?? claimedAt,
          attemptLeaseExpiresAt,
          updatedAt: claimedAt,
        })
        .where(
          eq(
            proWelcomeFulfillments.checkoutSessionId,
            input.checkoutSessionId,
          ),
        );
    }
    return "claimed";
  });
}

async function releaseProWelcomeDeliveryAttempt(
  db: ReturnType<typeof cloudDb>,
  input: ProWelcomeDeliveryIdentity,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${`pro-welcome:${input.checkoutSessionId}`}, 0))`,
    );
    await tx
      .update(proWelcomeFulfillments)
      .set({
        attemptLeaseExpiresAt: null,
        updatedAt: new Date(),
      })
      .where(
        eq(
          proWelcomeFulfillments.checkoutSessionId,
          input.checkoutSessionId,
        ),
      );
  });
}

async function markProWelcomeDeliverySent(
  db: ReturnType<typeof cloudDb>,
  input: ProWelcomeDeliveryIdentity,
  sentAt: Date,
): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(input.stackUserId)}, 0))`,
    );
    await tx.execute(
      sql`select pg_advisory_xact_lock(hashtextextended(${`pro-welcome:${input.checkoutSessionId}`}, 0))`,
    );
    await tx
      .update(proWelcomeFulfillments)
      .set({
        sentAt,
        attemptLeaseExpiresAt: null,
        updatedAt: sentAt,
      })
      .where(
        eq(
          proWelcomeFulfillments.checkoutSessionId,
          input.checkoutSessionId,
        ),
      );
  });
}

export async function buildProWelcomeEmail(input: {
  from: string;
  to: string;
  customerName?: string | null;
  locale: Locale;
  sessionRef: string;
}): Promise<ProWelcomeEmail> {
  const catalog = await loadMessages(input.locale) as {
    emails: { proWelcome: ProWelcomeCopy };
  };
  const copy = catalog.emails.proWelcome;
  const name = firstName(input.customerName) ?? copy.fallbackName;
  const greeting = copy.greeting.replace("{name}", name);
  const testflightLink = copy.testflightLink.replace(
    "{url}",
    PRO_TESTFLIGHT_SIGNUP_URL,
  );
  return {
    from: input.from,
    to: [input.to],
    replyTo: PRO_REPLY_TO_EMAIL,
    subject: copy.subject,
    text: [
      greeting,
      "",
      copy.thanks,
      "",
      copy.cloudStatus,
      "",
      copy.currentBenefit,
      "",
      testflightLink,
      "",
      copy.signoff,
    ].join("\n"),
    html: [
      `<p>${escapeHtml(greeting)}</p>`,
      `<p>${escapeHtml(copy.thanks)}</p>`,
      `<p>${escapeHtml(copy.cloudStatus)}</p>`,
      `<p>${escapeHtml(copy.currentBenefit)}</p>`,
      `<p><a href="${PRO_TESTFLIGHT_SIGNUP_URL}">${escapeHtml(copy.testflightLinkLabel)}</a></p>`,
      `<p>${escapeHtml(copy.signoff).replaceAll("\n", "<br>")}</p>`,
    ].join(""),
    headers: { "X-Entity-Ref-ID": `pro-welcome/${input.sessionRef}` },
  };
}

function checkoutEmail(session: Stripe.Checkout.Session): string | null {
  const email = session.customer_details?.email ?? expandedCustomer(session)?.email;
  const normalized = email?.trim().toLowerCase();
  return normalized || null;
}

function checkoutCustomerName(session: Stripe.Checkout.Session): string | null {
  const name = session.customer_details?.name ?? expandedCustomer(session)?.name;
  const normalized = name?.trim();
  return normalized || null;
}

function checkoutLocale(session: Stripe.Checkout.Session): Locale {
  const sessionLocale = session.locale === "auto" ? null : session.locale;
  const preferredLocale = expandedCustomer(session)?.preferred_locales?.[0];
  const locale = (sessionLocale ?? preferredLocale ?? "").trim().toLowerCase();
  const alias = checkoutLocaleAliases[locale];
  return alias ?? preferredLocaleFromAcceptLanguage(locale);
}

const checkoutLocaleAliases: Readonly<Record<string, Locale>> = {
  "en-gb": "en",
  "es-419": "es",
  "fr-ca": "fr",
  nb: "no",
  pt: "pt-BR",
  zh: "zh-CN",
  "zh-hk": "zh-TW",
};

function expandedCustomer(session: Stripe.Checkout.Session): Stripe.Customer | null {
  const customer = session.customer;
  if (typeof customer !== "object" || customer === null) return null;
  if ("deleted" in customer && customer.deleted) return null;
  return customer as Stripe.Customer;
}

function firstName(name: string | null | undefined): string | null {
  return name?.trim().split(/\s+/)[0] || null;
}

function formatFromAddress(email: string): string {
  return `cmux Pro <${email}>`;
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
