import { createHmac, timingSafeEqual } from "node:crypto";

import { NextResponse } from "next/server";
import { Resend } from "resend";

import { env } from "@/app/env";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "@/services/telemetry";

import {
  DEFAULT_FROM_EMAIL,
  buildFoundersWelcomeEmail,
  buildProWelcomeEmail,
} from "./welcome-email";
import {
  sessionProductMarkerIsAuthoritative,
  welcomeTriggerForCheckout,
} from "./welcome-trigger";
import { locales, type Locale } from "../../../../i18n/routing";
import { personalProWelcomeOwnsDelivery } from "../../../../services/billing/personalProWelcome";
import { stripe } from "../../../../services/billing/stripe";

// to blunt replay attempts.
const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

type FoundersConfig = {
  resendApiKey: string;
  webhookSecret: string;
  fromEmail: string;
};

type FoundersWelcomeDependencies = {
  personalProWelcomeEnabled: () => boolean;
  retrieveSubscription: (
    subscriptionId: string,
  ) => Promise<{ metadata?: Record<string, string> | null }>;
};

const defaultDependencies: FoundersWelcomeDependencies = {
  personalProWelcomeEnabled: () =>
    personalProWelcomeOwnsDelivery({
      enabled: env.CMUX_PERSONAL_PRO_WELCOME_ENABLED,
      resendApiKey: env.RESEND_API_KEY,
      webhookSecret: env.STRIPE_FOUNDERS_WEBHOOK_SECRET,
      stripeSecretKey: env.STRIPE_SECRET_KEY,
    }),
  retrieveSubscription: async (subscriptionId) =>
    stripe().subscriptions.retrieve(subscriptionId),
};

function resolveConfig(): FoundersConfig | null {
  const resendApiKey = env.RESEND_API_KEY;
  const webhookSecret = env.STRIPE_FOUNDERS_WEBHOOK_SECRET;
  if (!resendApiKey || !webhookSecret) {
    return null;
  }
  return {
    resendApiKey,
    webhookSecret,
    fromEmail: env.CMUX_FOUNDERS_FROM_EMAIL ?? DEFAULT_FROM_EMAIL,
  };
}

// Verify the `Stripe-Signature` header without depending on the stripe SDK.
// Header format: `t=<unix>,v1=<hex>,v1=<hex>...` — the signed payload is
// `<t>.<rawBody>` and each v1 entry is its HMAC-SHA256 under the endpoint secret.
function isValidStripeSignature(
  rawBody: string,
  header: string | null,
  secret: string,
  nowSeconds: number,
): boolean {
  if (!header) {
    return false;
  }
  let timestamp = "";
  const signatures: string[] = [];
  for (const part of header.split(",")) {
    const [key, value] = part.split("=", 2);
    if (key === "t") {
      timestamp = value ?? "";
    } else if (key === "v1" && value) {
      signatures.push(value);
    }
  }
  if (!timestamp || signatures.length === 0) {
    return false;
  }
  const timestampSeconds = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(timestampSeconds)) {
    return false;
  }
  if (Math.abs(nowSeconds - timestampSeconds) > SIGNATURE_TOLERANCE_SECONDS) {
    return false;
  }
  const expected = createHmac("sha256", secret)
    .update(`${timestamp}.${rawBody}`)
    .digest("hex");
  const expectedBuffer = Buffer.from(expected, "hex");
  return signatures.some((candidate) => {
    let candidateBuffer: Buffer;
    try {
      candidateBuffer = Buffer.from(candidate, "hex");
    } catch {
      return false;
    }
    return (
      candidateBuffer.length === expectedBuffer.length &&
      timingSafeEqual(candidateBuffer, expectedBuffer)
    );
  });
}

export function makeFoundersWelcomeHandler(
  dependencies: Partial<FoundersWelcomeDependencies> = {},
) {
  const resolvedDependencies = { ...defaultDependencies, ...dependencies };
  return async function POST(request: Request) {
    return withApiRouteSpan(
      request,
      "/api/stripe/founders-welcome",
      { "cmux.subsystem": "stripe", "cmux.stripe.operation": "founders_welcome" },
      async (span): Promise<Response> => {
      const config = resolveConfig();
      if (!config) {
        return jsonError("Founders welcome endpoint is not configured", 503);
      }

      const rawBody = await request.text();
      const nowSeconds = Math.floor(Date.now() / 1000);
      const valid = isValidStripeSignature(
        rawBody,
        request.headers.get("stripe-signature"),
        config.webhookSecret,
        nowSeconds,
      );
      setSpanAttributes(span, { "cmux.stripe.signature_valid": valid });
      if (!valid) {
        return jsonError("Invalid Stripe signature", 400);
      }

      let event: StripeEvent;
      try {
        event = JSON.parse(rawBody) as StripeEvent;
      } catch {
        return jsonError("Invalid JSON payload", 400);
      }

      setSpanAttributes(span, { "cmux.stripe.event_type": event.type ?? "" });

      // This endpoint owns the personal welcome for Founder's Edition and Pro.
      // Team and unrecognized checkouts are acknowledged without mail. Explicit
      // Session product markers take precedence. Some Stripe checkout flows
      // put the product metadata only on the expanded subscription, so pass
      // that metadata to the shared classifier as a fallback.
      if (
        event.type !== "checkout.session.completed" &&
        event.type !== "checkout.session.async_payment_succeeded"
      ) {
        return NextResponse.json({ ok: true, skipped: "event_type" });
      }
      const session = event.data?.object;
      let subscriptionMetadata =
        session?.subscription && typeof session.subscription === "object"
          ? session.subscription.metadata
          : null;
      if (
        !subscriptionMetadata &&
        typeof session?.subscription === "string" &&
        !sessionProductMarkerIsAuthoritative(session.metadata)
      ) {
        try {
          subscriptionMetadata = (
            await resolvedDependencies.retrieveSubscription(session.subscription)
          ).metadata ?? null;
        } catch (error) {
          recordSpanError(span, error);
          console.error("stripe.founders_welcome.subscription_lookup_failed");
          return jsonError("Unable to resolve checkout metadata", 503);
        }
      }
      const trigger = welcomeTriggerForCheckout(
        session?.metadata,
        subscriptionMetadata,
      );
      const customerEmail = session?.customer_details?.email ?? null;
      setSpanAttributes(span, {
        "cmux.stripe.is_founders": trigger === "founders_edition",
        "cmux.stripe.welcome_trigger": trigger,
        "cmux.stripe.has_customer_email": Boolean(customerEmail),
      });
      if (trigger !== "founders_edition" && trigger !== "pro_plan") {
        return NextResponse.json({ ok: true, skipped: "not_welcome_eligible" });
      }
      if (
        trigger === "pro_plan" &&
        !resolvedDependencies.personalProWelcomeEnabled()
      ) {
        return NextResponse.json({ ok: true, skipped: "pro_rollout_disabled" });
      }
      if (
        event.type === "checkout.session.completed" &&
        session?.payment_status !== "paid" &&
        session?.payment_status !== "no_payment_required"
      ) {
        // Delayed payment methods can emit `completed` before funds settle;
        // wait for `async_payment_succeeded` before sending a welcome.
        return NextResponse.json({ ok: true, skipped: "payment_pending" });
      }
      if (!customerEmail) {
        // A completed session that arrives without a customer email is
        // diagnosable in telemetry rather than a silent miss.
        return NextResponse.json({ ok: true, skipped: "no_customer_email" });
      }

      // Stripe delivers webhooks at least once and retries after a transient
      // failure (including one observed after Resend already accepted the
      // message), so key the send by the checkout session id. This same ref
      // both deduplicates the send (via the Resend idempotency key, which
      // dedupes identical sends for 24h) and threads the email (via the
      // X-Entity-Ref-ID header inside buildFoundersWelcomeEmail): redelivery of
      // the same purchase neither sends a second welcome nor spawns a second
      // Gmail thread, while a new subscription gets its own thread.
      const sessionRef = session?.id ?? event.id ?? customerEmail;
      const idempotencyKey = `founders-welcome/${sessionRef}`;
      // Only attach the personal display name to the default sender. If the
      // address is overridden to a shared/team inbox, send from the bare
      // address rather than a mismatched "Austin Wang" identity.
      const fromAddress =
        config.fromEmail === DEFAULT_FROM_EMAIL
          ? `Austin Wang <${config.fromEmail}>`
          : config.fromEmail;
      const resend = new Resend(config.resendApiKey);
      const emailPayload = trigger === "pro_plan"
        ? await buildProWelcomeEmail({
            from: fromAddress,
            to: customerEmail,
            customerName: session?.customer_details?.name,
            sessionRef,
            locale: localeForSession(session),
          })
        : buildFoundersWelcomeEmail({
            from: fromAddress,
            to: customerEmail,
            customerName: session?.customer_details?.name,
            sessionRef,
          });
      const { error } = await resend.emails.send(
        emailPayload,
        { idempotencyKey },
      );

      if (error) {
        recordSpanError(span, error);
        console.error("stripe.founders_welcome.resend_failed", error);
        // Non-2xx so Stripe retries and the email is not silently lost.
        return jsonError("Failed to send welcome email", 502);
      }

      return NextResponse.json(
        { ok: true, sent: true },
        { headers: { "Cache-Control": "no-store" } },
      );
      },
    );
  };
}

export const POST = makeFoundersWelcomeHandler();

function jsonError(message: string, status: number): Response {
  return NextResponse.json(
    { error: message },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}

type StripeEvent = {
  id?: string;
  type?: string;
  data?: {
    object?: {
      id?: string;
      metadata?: Record<string, string> | null;
      subscription?:
        | string
        | {
            metadata?: Record<string, string> | null;
          }
        | null;
      customer_details?: {
        email?: string | null;
        name?: string | null;
      } | null;
      payment_status?: string | null;
      locale?: string | null;
    };
  };
};

type StripeSessionPayload = NonNullable<
  NonNullable<StripeEvent["data"]>["object"]
>;

function localeForSession(session: StripeSessionPayload | undefined): Locale {
  const value =
    session && typeof session === "object" && "locale" in session
      ? (session as { locale?: unknown }).locale
      : undefined;
  if (typeof value !== "string") return "en";
  const trimmed = value.trim();
  const normalized = trimmed.toLowerCase();
  const aliases: Record<string, Locale> = {
    "en-gb": "en",
    "es-419": "es",
    "fr-ca": "fr",
    nb: "no",
    pt: "pt-BR",
    "pt-br": "pt-BR",
    zh: "zh-CN",
    "zh-cn": "zh-CN",
    "zh-hk": "zh-TW",
    "zh-tw": "zh-TW",
  };
  // Keep the catalog's case-sensitive regional keys when Stripe already
  // supplied one, while accepting lowercase provider aliases as well.
  const aliased = aliases[normalized] ?? trimmed;
  return (locales as readonly string[]).includes(aliased)
    ? (aliased as Locale)
    : "en";
}
