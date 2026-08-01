// Source B for both audiences: Founder's Edition buyers, from Stripe.
//
// The Stripe Checkout Sessions API is the authoritative record of a
// Founder's Edition purchase. The payment link stamps
// `founders_edition=true` onto every session it creates (the same signal
// /api/stripe/founders-welcome keys the welcome email on), and the buyer's
// email and name live on the completed session's customer_details.
//
// The stripe_customers / billing_email_claims Postgres tables are NOT used
// as a source: they are projections maintained by the Pro/Team billing
// webhooks and are keyed by Stack user id. A founder who bought through the
// payment link without ever creating a Stack account has no row there, so
// treating the database as authoritative would silently drop paying
// customers. Stripe's own ledger has every purchase.

import {
  type NewsletterContact,
  normalizeEmail,
  splitDisplayName,
} from "./contacts";
import type { FetchLike } from "./resend-client";

const STRIPE_API_BASE = "https://api.stripe.com";
const PAGE_LIMIT = 100;

type StripeCheckoutSession = {
  id: string;
  status?: string | null;
  payment_status?: string | null;
  metadata?: Record<string, string> | null;
  customer_details?: {
    email?: string | null;
    name?: string | null;
  } | null;
};

type StripeListPage = {
  data?: StripeCheckoutSession[];
  has_more?: boolean;
};

export type StripeSourceResult = {
  contacts: NewsletterContact[];
  totalSessions: number;
  founderSessions: number;
  skippedMissingEmail: number;
};

export async function listFounderContacts(options: {
  stripeSecretKey: string;
  fetchImpl?: FetchLike;
}): Promise<StripeSourceResult> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
  const byEmail = new Map<string, NewsletterContact>();
  let totalSessions = 0;
  let founderSessions = 0;
  let skippedMissingEmail = 0;
  let startingAfter: string | null = null;

  for (;;) {
    const query = new URLSearchParams({ limit: String(PAGE_LIMIT) });
    if (startingAfter) {
      query.set("starting_after", startingAfter);
    }
    const response = await fetchImpl(
      `${STRIPE_API_BASE}/v1/checkout/sessions?${query.toString()}`,
      {
        method: "GET",
        headers: { Authorization: `Bearer ${options.stripeSecretKey}` },
      },
    );
    const text = await response.text();
    if (response.status >= 400) {
      throw new Error(
        `Stripe checkout session listing failed with ${response.status}: ${text.slice(0, 200)}`,
      );
    }
    const page = JSON.parse(text) as StripeListPage;
    const sessions = page.data ?? [];
    for (const session of sessions) {
      totalSessions += 1;
      if (session.metadata?.founders_edition !== "true") {
        continue;
      }
      if (session.status !== "complete") {
        continue;
      }
      // A complete session is normally "paid"; "no_payment_required" covers a
      // 100%-off promotion, which is still a real founder.
      if (
        session.payment_status !== "paid" &&
        session.payment_status !== "no_payment_required"
      ) {
        continue;
      }
      founderSessions += 1;
      const email = normalizeEmail(session.customer_details?.email);
      if (!email) {
        skippedMissingEmail += 1;
        continue;
      }
      if (byEmail.has(email)) {
        continue;
      }
      byEmail.set(email, {
        email,
        ...splitDisplayName(session.customer_details?.name),
        sources: ["stripe"],
      });
    }
    if (!page.has_more) {
      break;
    }
    const nextAfter = sessions.length > 0 ? sessions[sessions.length - 1].id : null;
    if (!nextAfter || nextAfter === startingAfter) {
      throw new Error(
        "Stripe pagination made no progress; refusing to continue with a " +
          "truncated checkout session listing.",
      );
    }
    startingAfter = nextAfter;
  }

  return {
    contacts: [...byEmail.values()],
    totalSessions,
    founderSessions,
    skippedMissingEmail,
  };
}
