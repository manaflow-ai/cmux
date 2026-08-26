import { createHmac, timingSafeEqual } from "node:crypto";

import { after, NextResponse } from "next/server";
import { Resend } from "resend";

import { env } from "@/app/env";
import {
  upsertFounderIntoSegments,
  withDeadline,
} from "@/services/newsletter/founder-hook";
import { ResendClient } from "@/services/newsletter/resend-client";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "@/services/telemetry";

import {
  DEFAULT_FROM_EMAIL,
  buildFoundersWelcomeEmail,
} from "./welcome-email";
import { welcomeTriggerForMetadata } from "./welcome-trigger";

// to blunt replay attempts.
const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

// Upper bound on the best-effort newsletter segment upsert after a founder
// purchase. Kept well under Stripe's webhook timeout (with headroom for the
// welcome send that precedes it) so a Resend stall cannot push the
// acknowledgement into Stripe's retry window; anything missed is picked up
// by the manual reconciliation sync.
const NEWSLETTER_UPSERT_DEADLINE_MS = 5_000;

type FoundersConfig = {
  resendApiKey: string;
  webhookSecret: string;
  fromEmail: string;
  newsletterPrivacyDisclosureConfirmed: boolean;
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
    newsletterPrivacyDisclosureConfirmed:
      env.CMUX_NEWSLETTER_PRIVACY_DISCLOSURE_CONFIRMED === "true",
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

export async function POST(request: Request) {
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

      // Delayed payment methods complete their checkout session with
      // payment_status "unpaid" and report the real outcome later via
      // checkout.session.async_payment_succeeded. The welcome email already
      // went out at completion; this later event only needs the newsletter
      // segment upsert that the completion handler skipped while the
      // payment was unsettled. (The Stripe endpoint must be subscribed to
      // this event type for it to arrive here.)
      if (event.type === "checkout.session.async_payment_succeeded") {
        const asyncSession = event.data?.object;
        const asyncEmail = asyncSession?.customer_details?.email ?? null;
        const settled = isPaymentSettled(asyncSession);
        if (
          welcomeTriggerForMetadata(asyncSession?.metadata) !==
            "founders_edition" ||
          !asyncEmail ||
          !settled
        ) {
          return NextResponse.json({ ok: true, skipped: "async_payment" });
        }
        if (!config.newsletterPrivacyDisclosureConfirmed) {
          return NextResponse.json({
            ok: true,
            skipped: "privacy_disclosure",
          });
        }
        const upsert = await scheduleNewsletterUpsert(() =>
          upsertFounderBestEffort(span, config, {
            email: asyncEmail,
            customerName: asyncSession?.customer_details?.name,
          }),
        );
        return NextResponse.json(
          { ok: true, upsert },
          { headers: { "Cache-Control": "no-store" } },
        );
      }

      // Pro purchases have their own transactional welcome and TestFlight
      // fulfillment in /api/stripe/webhook. Acknowledge them here without
      // sending the personal Founder's Edition email as well. Explicit
      // Founder's Edition metadata wins in welcomeTriggerForMetadata, so its
      // behavior remains unchanged even if extra metadata is present.
      if (event.type !== "checkout.session.completed") {
        return NextResponse.json({ ok: true, skipped: "event_type" });
      }
      const session = event.data?.object;
      const trigger = welcomeTriggerForMetadata(session?.metadata);
      if (trigger === "pro_plan") {
        return NextResponse.json({ ok: true, skipped: "pro_plan" });
      }
      const customerEmail = session?.customer_details?.email ?? null;
      setSpanAttributes(span, {
        "cmux.stripe.is_founders": trigger === "founders_edition",
        "cmux.stripe.welcome_trigger": trigger,
        "cmux.stripe.has_customer_email": Boolean(customerEmail),
      });
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
      const { error } = await resend.emails.send(
        buildFoundersWelcomeEmail({
          from: fromAddress,
          to: customerEmail,
          customerName: session?.customer_details?.name,
          sessionRef,
        }),
        { idempotencyKey },
      );

      if (error) {
        const category = errorCategory(error);
        recordSpanError(span, new Error(category));
        console.error("stripe.founders_welcome.resend_failed", { category });
        // Non-2xx so Stripe retries and the email is not silently lost.
        return jsonError("Failed to send welcome email", 502);
      }

      // Purchase-time newsletter segment upsert (see
      // services/newsletter/founder-hook.ts). Best-effort by design: the
      // welcome email already went out, so a Resend hiccup (for example a
      // sending-only restricted key) must not fail the webhook and trigger a
      // Stripe retry storm. The whole upsert is bounded by a deadline so a
      // Resend stall cannot hold the webhook open, and the manual sync
      // script reconciles any contact missed here.
      //
      // Only sessions whose payment actually succeeded are added: Stripe
      // emits checkout.session.completed with payment_status "unpaid" for
      // delayed payment methods that may still fail, and the additive sync
      // would never remove a buyer whose payment later fell through.
      const paymentSettled = isPaymentSettled(session);
      if (
        trigger === "founders_edition" &&
        paymentSettled &&
        config.newsletterPrivacyDisclosureConfirmed
      ) {
        await scheduleNewsletterUpsert(() =>
          upsertFounderBestEffort(span, config, {
            email: customerEmail,
            customerName: session?.customer_details?.name,
          }),
        );
      }

      return NextResponse.json(
        { ok: true, sent: true },
        { headers: { "Cache-Control": "no-store" } },
      );
    },
  );
}

// Best-effort, deadline-bounded newsletter segment upsert. Never throws: a
// Resend failure is logged and recorded on the span, but must not turn an
// already-acknowledged purchase event into a webhook error and a Stripe
// retry storm. The deadline aborts the underlying Resend work (requests,
// pacing, backoff) so nothing keeps running after the webhook answers, and
// the manual reconciliation sync is the catch-up. Returns "completed" or
// "failed" so callers never report a failed upsert as successful.
async function upsertFounderBestEffort(
  span: Parameters<typeof setSpanAttributes>[0],
  config: FoundersConfig,
  buyer: { email: string; customerName?: string | null },
): Promise<"completed" | "failed"> {
  try {
    const abort = new AbortController();
    const results = await withDeadline(
      upsertFounderIntoSegments({
        client: new ResendClient({
          apiKey: config.resendApiKey,
          cancelSignal: abort.signal,
        }),
        email: buyer.email,
        customerName: buyer.customerName,
      }),
      NEWSLETTER_UPSERT_DEADLINE_MS,
      abort,
    );
    setSpanAttributes(span, {
      "cmux.newsletter.segment_outcomes": results
        .map((result) => `${result.segmentName}:${result.outcome}`)
        .join(","),
    });
    return results.some(
      (result) =>
        result.outcome === "failed" ||
        result.outcome === "skipped_missing_segment" ||
        result.outcome === "skipped_missing_contact",
    )
      ? "failed"
      : "completed";
  } catch (segmentError) {
    const category = newsletterErrorCategory(segmentError);
    recordSpanError(span, new Error(category));
    console.error(
      "stripe.founders_welcome.segment_upsert_failed",
      { category },
    );
    return "failed";
  }
}

// Next's after() keeps best-effort work alive after the 2xx response on the
// deployed runtime. Outside a request scope (unit tests and local scripts),
// fall back to awaiting the work so failures remain observable and tests stay
// deterministic.
async function scheduleNewsletterUpsert(
  work: () => Promise<"completed" | "failed">,
): Promise<"scheduled" | "completed" | "failed"> {
  try {
    after(async () => {
      await work();
    });
    return "scheduled";
  } catch {
    return work();
  }
}

function isPaymentSettled(session: {
  payment_status?: string | null;
  amount_total?: number | null;
} | null | undefined): boolean {
  if (session?.payment_status === "paid") return true;
  return session?.payment_status === "no_payment_required" && session.amount_total === 0;
}

function newsletterErrorCategory(error: unknown): string {
  if (error instanceof Error && /deadline/i.test(error.message)) {
    return "deadline_exceeded";
  }
  if (error instanceof Error && error.name === "ResendApiError") {
    return "provider_api_error";
  }
  return "unknown";
}

function errorCategory(error: unknown): string {
  if (error && typeof error === "object" && "name" in error) {
    const name = String((error as { name?: unknown }).name ?? "");
    if (name) return "provider_" + name.replace(/[^a-z0-9_]/gi, "_");
  }
  return "provider_error";
}

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
      payment_status?: string | null;
      amount_total?: number | null;
      customer_details?: {
        email?: string | null;
        name?: string | null;
      } | null;
    };
  };
};
