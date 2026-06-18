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
} from "./welcome-email";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Stripe checkout sessions created from the cmux Founder's Edition payment link
// carry this metadata key (copied automatically onto each session). We only send
// the welcome email when it is present and truthy.
const FOUNDERS_METADATA_KEY = "founders_edition";

// Stripe signs webhooks with a 5-minute default tolerance; reject older payloads
// to blunt replay attempts.
const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

type FoundersConfig = {
  resendApiKey: string;
  webhookSecret: string;
  fromEmail: string;
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

      // Only react to completed checkout sessions flagged as Founder's Edition.
      // Everything else (including renewals, which never create a checkout
      // session) is acknowledged with 200 so Stripe stops retrying.
      if (event.type !== "checkout.session.completed") {
        return NextResponse.json({ ok: true, skipped: "event_type" });
      }
      const session = event.data?.object;
      const isFounders =
        session?.metadata?.[FOUNDERS_METADATA_KEY] === "true";
      const customerEmail = session?.customer_details?.email ?? null;
      setSpanAttributes(span, {
        "cmux.stripe.is_founders": isFounders,
        "cmux.stripe.has_customer_email": Boolean(customerEmail),
      });
      if (!isFounders) {
        return NextResponse.json({ ok: true, skipped: "not_founders" });
      }
      if (!customerEmail) {
        // Distinct from "not_founders" so a Founder's session that arrives
        // without a customer email is diagnosable in telemetry rather than a
        // silent miss.
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
      customer_details?: {
        email?: string | null;
        name?: string | null;
      } | null;
    };
  };
};
