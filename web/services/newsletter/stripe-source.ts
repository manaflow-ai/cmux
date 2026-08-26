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
  nameScore,
  normalizeEmail,
  splitDisplayName,
} from "./contacts";
import type { FetchLike } from "./resend-client";
import { fetchSourceJson } from "./source-http";

const STRIPE_API_BASE = "https://api.stripe.com";
const PAGE_LIMIT = 100;
const MAX_PAGES = 10_000;

type StripeCheckoutSession = {
  id: string;
  status?: string | null;
  payment_status?: string | null;
  amount_total?: number | null;
  refunded?: boolean;
  payment_intent?:
    | string
    | {
        latest_charge?: {
          refunded?: boolean;
          disputed?: boolean;
          amount?: number | null;
          amount_refunded?: number | null;
        } | null;
      }
    | null;
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
  refundedSessions: number;
  revokedEmails: string[];
};

function isSettledFounderSession(session: StripeCheckoutSession): boolean {
  if (session.payment_status === "paid") return true;
  // Stripe also emits no_payment_required for genuinely zero-total sessions,
  // but the status alone is not proof that money is settled (it can represent
  // deferred/setup flows). Require the explicit zero-total invariant.
  return session.payment_status === "no_payment_required" && session.amount_total === 0;
}

export function isRefundedFounderSession(session: StripeCheckoutSession): boolean {
  if (session.refunded === true) return true;
  const charge =
    typeof session.payment_intent === "object"
      ? session.payment_intent?.latest_charge
      : null;
  return Boolean(
    charge?.refunded ||
      charge?.disputed ||
      (charge?.amount !== null &&
        charge?.amount !== undefined &&
        charge.amount_refunded !== null &&
        charge.amount_refunded !== undefined &&
        charge.amount_refunded >= charge.amount),
  );
}

export async function listFounderContacts(options: {
  stripeSecretKey: string;
  fetchImpl?: FetchLike;
  signal?: AbortSignal;
  maxPages?: number;
}): Promise<StripeSourceResult> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
  const byEmail = new Map<string, NewsletterContact>();
  let totalSessions = 0;
  let founderSessions = 0;
  let skippedMissingEmail = 0;
  let refundedSessions = 0;
  const revokedEmails = new Set<string>();
  const activeEmails = new Set<string>();
  let startingAfter: string | null = null;
  const seenCursors = new Set<string>();
  let pageCount = 0;

  for (;;) {
    if (startingAfter && seenCursors.has(startingAfter)) {
      throw new Error(
        "Stripe pagination repeated a cursor; refusing to continue with a " +
          "truncated checkout-session listing.",
      );
    }
    if (startingAfter) seenCursors.add(startingAfter);
    pageCount += 1;
    if (pageCount > (options.maxPages ?? MAX_PAGES)) {
      throw new Error(
        "Stripe pagination exceeded the safety page limit; refusing to " +
          "continue with an unbounded checkout-session listing.",
      );
    }
    // status=complete filters server-side so the run does not page through
    // every abandoned checkout the account has ever created; the in-loop
    // status check stays as a defensive invariant.
    const query = new URLSearchParams({
      limit: String(PAGE_LIMIT),
      status: "complete",
    });
    query.append("expand[]", "data.payment_intent.latest_charge");
    if (startingAfter) {
      query.set("starting_after", startingAfter);
    }
    const page = await fetchSourceJson<StripeListPage>({
      fetchImpl,
      url: `${STRIPE_API_BASE}/v1/checkout/sessions?${query.toString()}`,
      headers: { Authorization: `Bearer ${options.stripeSecretKey}` },
      label: "Stripe checkout session listing",
      signal: options.signal,
    });
    const sessions = page.data ?? [];
    for (const session of sessions) {
      totalSessions += 1;
      if (session.metadata?.founders_edition !== "true") {
        continue;
      }
      if (session.status !== "complete") {
        continue;
      }
      const email = normalizeEmail(session.customer_details?.email);
      if (!isSettledFounderSession(session)) {
        continue;
      }
      if (isRefundedFounderSession(session)) {
        refundedSessions += 1;
        if (email && !activeEmails.has(email)) revokedEmails.add(email);
        continue;
      }
      founderSessions += 1;
      if (!email) {
        skippedMissingEmail += 1;
        continue;
      }
      activeEmails.add(email);
      revokedEmails.delete(email);
      const name = splitDisplayName(session.customer_details?.name);
      const existing = byEmail.get(email);
      if (!existing) {
        byEmail.set(email, { email, ...name, sources: ["stripe"] });
        continue;
      }
      // A founder can have several checkout sessions; keep the most
      // complete name across them rather than whichever came first.
      if (nameScore(name) > nameScore(existing)) {
        existing.firstName = name.firstName;
        existing.lastName = name.lastName;
      }
    }
    if (!page.has_more) {
      break;
    }
    const nextAfter = sessions.length > 0 ? sessions[sessions.length - 1].id : null;
    // Guard against cursor cycles of any length, not just an immediately
    // repeated cursor.
    if (!nextAfter || seenCursors.has(nextAfter)) {
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
    refundedSessions,
    revokedEmails: [...revokedEmails],
  };
}
