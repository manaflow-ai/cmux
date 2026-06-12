import { createHmac, timingSafeEqual } from "node:crypto";

import { NextResponse } from "next/server";
import { Resend } from "resend";

import { env } from "@/app/env";
import {
  recordSpanError,
  setSpanAttributes,
  withApiRouteSpan,
} from "@/services/telemetry";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Stripe checkout sessions created from the cmux Founder's Edition payment link
// carry this metadata key (copied automatically onto each session). We only send
// the welcome email when it is present and truthy.
const FOUNDERS_METADATA_KEY = "founders_edition";

// Default sender/recipients. Sender is overridable via env so the verified Resend
// domain can change without a code edit; the founders are always copied so both
// see exactly what the customer received.
const DEFAULT_FROM_EMAIL = "austin@manaflow.ai";
const FOUNDER_CC = ["austin@manaflow.ai", "lawrence@manaflow.ai"];
const REPLY_TO = "austin@manaflow.ai";
const EMAIL_SUBJECT = "cmux Founder's Edition";

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

function firstName(fullName: string | null | undefined): string {
  const trimmed = (fullName ?? "").trim();
  if (!trimmed) {
    return "there";
  }
  return trimmed.split(/\s+/)[0];
}

function buildBody(name: string): string {
  return [
    `Hi ${name}!`,
    "",
    "Thank you for being one of the first ever customers of cmux :)",
    "",
    "My number is +1(714) 699-0169 and Lawrence's number is +1(949) 302-0749. " +
      "Our emails are austin@manaflow.ai and lawrence@manaflow.ai. Feel free to " +
      "text me on iMessage or WhatsApp, or we can just continue talking here. " +
      "I've CC'd my cofounder as well.",
    "",
    "Best,",
    "Austin",
  ].join("\n");
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
      if (!isFounders || !customerEmail) {
        return NextResponse.json({ ok: true, skipped: "not_founders" });
      }

      const name = firstName(session?.customer_details?.name);
      // Stripe delivers webhooks at least once and retries after a transient
      // failure (including one observed after Resend already accepted the
      // message), so key the send by the checkout session id. Resend
      // deduplicates identical sends for 24h, so redelivery of the same
      // purchase will not send a second welcome email.
      const idempotencyKey = `founders-welcome/${session?.id ?? event.id ?? customerEmail}`;
      const resend = new Resend(config.resendApiKey);
      const { error } = await resend.emails.send(
        {
          from: `Austin Wang <${config.fromEmail}>`,
          to: [customerEmail],
          cc: FOUNDER_CC,
          replyTo: REPLY_TO,
          subject: EMAIL_SUBJECT,
          text: buildBody(name),
        },
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
