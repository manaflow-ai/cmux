import { createHash } from "node:crypto";

import { eq, sql } from "drizzle-orm";
import { NextResponse } from "next/server";
import type Stripe from "stripe";

import { env } from "../../../env";
import { cloudDb } from "../../../../db/client";
import { stripeWebhookEvents } from "../../../../db/schema";
import { captureBillingError } from "../../../../services/errors";
import {
  applySubscriptionUpdate as applySubscriptionUpdateDefault,
  isCmuxCheckoutSession,
  recordCheckoutCompletion as recordCheckoutCompletionDefault,
} from "../../../../services/billing/purchase";
import { isStripeBillingConfigured, stripe } from "../../../../services/billing/stripe";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "../../../../services/telemetry";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type StripeWebhookDependencies = {
  webhookSecret: () => string | undefined;
  isConfigured: () => boolean;
  stripe: typeof stripe;
  db: typeof cloudDb;
  recordCheckoutCompletion: typeof recordCheckoutCompletionDefault;
  applySubscriptionUpdate: typeof applySubscriptionUpdateDefault;
};

const defaultDependencies: StripeWebhookDependencies = {
  webhookSecret: () => env.STRIPE_WEBHOOK_SECRET,
  isConfigured: isStripeBillingConfigured,
  stripe,
  db: cloudDb,
  recordCheckoutCompletion: recordCheckoutCompletionDefault,
  applySubscriptionUpdate: applySubscriptionUpdateDefault,
};

export const POST = makeStripeWebhookHandler();

export function makeStripeWebhookHandler(
  dependencies: StripeWebhookDependencies = defaultDependencies,
) {
  return async function POST(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/stripe/webhook",
    { "cmux.subsystem": "stripe", "cmux.stripe.operation": "billing_webhook" },
    async (span): Promise<Response> => {
      const webhookSecret = dependencies.webhookSecret();
      if (!webhookSecret || !dependencies.isConfigured()) {
        return jsonError("Stripe billing webhook is not configured", 503);
      }

      const rawBody = await request.text();
      let event: Stripe.Event;
      try {
        event = dependencies.stripe().webhooks.constructEvent(
          rawBody,
          request.headers.get("stripe-signature") ?? "",
          webhookSecret,
        );
      } catch {
        return jsonError("Invalid Stripe signature", 400);
      }

      setSpanAttributes(span, { "cmux.stripe.event_type": event.type });
      const db = dependencies.db();
      const [inserted] = await db
        .insert(stripeWebhookEvents)
        .values({
          id: event.id,
          type: event.type,
          payloadHash: payloadHash(rawBody),
        })
        .onConflictDoNothing({ target: stripeWebhookEvents.id })
        .returning({ id: stripeWebhookEvents.id });

      if (!inserted) {
        const [existing] = await db
          .select({
            processedAt: stripeWebhookEvents.processedAt,
            error: stripeWebhookEvents.error,
          })
          .from(stripeWebhookEvents)
          .where(eq(stripeWebhookEvents.id, event.id))
          .limit(1);
        if (existing?.processedAt && !existing.error) {
          return NextResponse.json({ ok: true, skipped: "duplicate" });
        }
      }

      try {
        const result = await processStripeEvent(event, dependencies);
        await db
          .update(stripeWebhookEvents)
          .set({ processedAt: sql`now()`, error: null })
          .where(eq(stripeWebhookEvents.id, event.id));
        return NextResponse.json({ ok: true, ...result });
      } catch (error) {
        recordSpanError(span, error);
        captureBillingError(error, {
          route: "/api/stripe/webhook",
          eventType: event.type,
        });
        await db
          .update(stripeWebhookEvents)
          .set({
            error: error instanceof Error ? error.message : String(error),
          })
          .where(eq(stripeWebhookEvents.id, event.id));
        return jsonError("Stripe webhook processing failed", 500);
      }
    },
  );
  };
}

async function processStripeEvent(
  event: Stripe.Event,
  dependencies: StripeWebhookDependencies,
): Promise<{ processed?: string; skipped?: string }> {
  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object;
      if (!isCmuxCheckoutSession(session)) return { skipped: "foreign_checkout" };
      const expanded = await dependencies.stripe().checkout.sessions.retrieve(session.id, {
        expand: ["subscription", "customer"],
      });
      const result = await dependencies.recordCheckoutCompletion({
        session: expanded,
        subscription: expandedSubscription(expanded),
        customer: expandedCustomer(expanded),
      });
      if (result && "skipped" in result) return { skipped: result.skipped };
      return { processed: "checkout.session.completed" };
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const result = await dependencies.applySubscriptionUpdate(event.data.object);
      return "skipped" in result
        ? { skipped: "subscription_unmapped" }
        : { processed: event.type };
    }
    case "invoice.paid":
    case "invoice.payment_failed": {
      const subscriptionId = invoiceSubscriptionId(event.data.object);
      if (!subscriptionId) return { skipped: "invoice_without_subscription" };
      const subscription = await dependencies.stripe().subscriptions.retrieve(subscriptionId);
      const result = await dependencies.applySubscriptionUpdate(subscription);
      return "skipped" in result
        ? { skipped: "invoice_subscription_unmapped" }
        : { processed: event.type };
    }
    default:
      return { skipped: "event_type" };
  }
}

function expandedSubscription(session: Stripe.Checkout.Session): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription !== null
    ? session.subscription
    : null;
}

function expandedCustomer(
  session: Stripe.Checkout.Session,
): Stripe.Customer | Stripe.DeletedCustomer | null {
  return typeof session.customer === "object" && session.customer !== null
    ? session.customer
    : null;
}

function invoiceSubscriptionId(invoice: Stripe.Invoice): string | null {
  const invoiceWithSubscription = invoice as Stripe.Invoice & {
    subscription?: string | Stripe.Subscription | null;
  };
  if (invoiceWithSubscription.subscription) {
    return stringId(invoiceWithSubscription.subscription);
  }
  const parent = invoice.parent as
    | {
        subscription_details?: {
          subscription?: string | Stripe.Subscription | null;
        } | null;
      }
    | null
    | undefined;
  return stringId(parent?.subscription_details?.subscription);
}

function stringId(value: string | { id: string } | null | undefined): string | null {
  if (!value) return null;
  return typeof value === "string" ? value : value.id;
}

function payloadHash(rawBody: string): string {
  return createHash("sha256").update(rawBody).digest("hex");
}

function jsonError(message: string, status: number): Response {
  return NextResponse.json(
    { error: message },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}
