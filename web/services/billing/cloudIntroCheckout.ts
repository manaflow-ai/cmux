import { and, eq, isNull } from "drizzle-orm";
import { NextResponse, type NextRequest } from "next/server";
import type Stripe from "stripe";

import { requestOrigin } from "../../app/lib/request-origin";
import { cloudDb } from "../../db/client";
import { stripeCustomers } from "../../db/schema";
import { captureBillingError } from "../errors";
import {
  CLOUD_INTRO_CHECKOUT_PLAN,
  CLOUD_INTRO_CHECKOUT_PURPOSE,
  CLOUD_INTRO_PRICING_USD,
  CLOUD_INTRO_RECEIPT_DESCRIPTION,
  CLOUD_INTRO_RENEW_PARAM,
  CLOUD_INTRO_STATEMENT_SUFFIX,
  cloudIntroRefusal,
  cloudIntroRefusalBillingCode,
  cloudIntroRenewChosen,
  isCloudIntroEnabled,
} from "./cloudIntro";
import {
  createDrizzleCloudIntroAccountFacts,
  createDrizzleCloudIntroPassStore,
  type CloudIntroAccountFactsQuery,
  type CloudIntroAccountUser,
  type CloudIntroPassStore,
} from "./cloudIntroPasses";
import { checkoutIdempotencyKey } from "./checkoutIdempotency";
import { isStripeBillingConfigured, stripe as defaultStripe } from "./stripe";

/**
 * `GET /api/billing/checkout?plan=intro`: a Stripe Checkout Session for the
 * $1 pass. It is a one-time payment (`mode: "payment"`) with 3-D Secure
 * requested. `renew=1` is the buyer's "continue on Plus after 30 days"
 * choice; only then is the card saved for off-session use. Fulfillment is the
 * webhook's (services/billing/cloudIntroFulfillment.ts); the success page only
 * shows the result.
 *
 * Returns null when the flag is off or the request is not for the pass, so the
 * route answers exactly as it did before the pass existed.
 */
type CheckoutUser = CloudIntroAccountUser & {
  readonly isAnonymous?: boolean;
  readonly primaryEmail?: string | null;
};

type CloudIntroCheckoutStripe = {
  readonly checkout: { readonly sessions: Pick<Stripe["checkout"]["sessions"], "create"> };
  readonly prices: Pick<Stripe["prices"], "list">;
};

export type CloudIntroCheckoutContext = {
  readonly stackServerApp: () => Promise<{
    getUser(options: { or: "return-null" }): Promise<CheckoutUser | null>;
  } | null>;
  readonly signInRedirect: (request: NextRequest) => NextResponse;
};

export type CloudIntroCheckoutDependencies = {
  readonly env?: Record<string, string | undefined>;
  readonly now?: () => Date;
  readonly isStripeConfigured?: () => boolean;
  readonly stripe?: () => CloudIntroCheckoutStripe;
  readonly store?: CloudIntroPassStore;
  readonly accountFacts?: CloudIntroAccountFactsQuery;
  readonly customerId?: (stackUserId: string) => Promise<string | null>;
};

export function isCloudIntroCheckoutRequest(
  request: NextRequest,
  env: Record<string, string | undefined> = process.env,
): boolean {
  const plan = request.nextUrl.searchParams.get("plan")?.trim().toLowerCase();
  return plan === CLOUD_INTRO_CHECKOUT_PLAN && isCloudIntroEnabled(env);
}

export async function cloudIntroCheckoutResponse(
  request: NextRequest,
  context: CloudIntroCheckoutContext,
  dependencies: CloudIntroCheckoutDependencies = {},
): Promise<NextResponse | null> {
  if (!isCloudIntroCheckoutRequest(request, dependencies.env)) return null;
  const app = await context.stackServerApp();
  if (!app || !(dependencies.isStripeConfigured ?? isStripeBillingConfigured)()) {
    return pricingRedirect(request, "unavailable");
  }
  try {
    const user = await app.getUser({ or: "return-null" });
    if (!user || user.isAnonymous) return context.signInRedirect(request);
    if (isAccountDeleting(user)) return pricingRedirect(request, "account_deletion_in_progress");
    return await createPassCheckout(request, user, dependencies);
  } catch (error) {
    captureBillingError(error, { route: "/api/billing/checkout", plan: CLOUD_INTRO_CHECKOUT_PLAN });
    return pricingRedirect(request, "error");
  }
}

async function createPassCheckout(
  request: NextRequest,
  user: CheckoutUser,
  dependencies: CloudIntroCheckoutDependencies,
): Promise<NextResponse> {
  const store = dependencies.store ?? createDrizzleCloudIntroPassStore();
  const account = await (dependencies.accountFacts ?? createDrizzleCloudIntroAccountFacts())(user);
  const storeFacts = await store.checkoutFacts({
    stackUserId: user.id,
    stackTeamIds: account.stackTeamIds,
    now: dependencies.now?.() ?? new Date(),
  });
  // Over a cap or ineligible: answer before anything is charged.
  const refusal = cloudIntroRefusal({ ...storeFacts, ...account }, "checkout");
  if (refusal) return pricingRedirect(request, cloudIntroRefusalBillingCode(refusal));

  const client = (dependencies.stripe ?? defaultStripe)();
  const renewOnPlus = cloudIntroRenewChosen(request.nextUrl.searchParams.get(CLOUD_INTRO_RENEW_PARAM));
  const customerId = await (dependencies.customerId ?? personalCustomerId)(user.id);
  const params = cloudIntroCheckoutParams({
    origin: requestOrigin(request),
    stackUserId: user.id,
    priceId: await resolveCloudIntroPrice(client),
    renewOnPlus,
    customerId,
    email: user.primaryEmail ?? null,
  });
  // A repeated identical request reuses its session, so it is one card attempt, not two.
  const session = await client.checkout.sessions.create(params, {
    idempotencyKey: checkoutIdempotencyKey({
      scope: "cloud-intro",
      subjectId: user.id,
      plan: CLOUD_INTRO_CHECKOUT_PLAN,
      interval: "once",
      params,
      now: dependencies.now?.().getTime(),
    }),
  });
  if (!session.id || !session.url) throw new Error("Stripe Checkout Session did not include an id and URL");
  // The started checkout counts as one of the account's card attempts.
  await store.recordCheckout({
    checkoutSessionId: session.id,
    stackUserId: user.id,
    stackTeamIds: account.stackTeamIds,
    renewOnPlus,
  });
  return NextResponse.redirect(session.url);
}

export type CloudIntroCheckoutInput = {
  readonly origin: string;
  readonly stackUserId: string;
  readonly priceId: string;
  readonly renewOnPlus: boolean;
  readonly customerId: string | null;
  readonly email: string | null;
};

/** The Checkout Session parameters for the pass. No promotion codes; no subscription. */
export function cloudIntroCheckoutParams(input: CloudIntroCheckoutInput): Stripe.Checkout.SessionCreateParams {
  const metadata = {
    app: "cmux",
    purpose: CLOUD_INTRO_CHECKOUT_PURPOSE,
    plan: CLOUD_INTRO_CHECKOUT_PLAN,
    stackUserId: input.stackUserId,
    renewOnPlus: input.renewOnPlus ? "true" : "false",
  };
  return {
    mode: "payment",
    payment_method_types: ["card"],
    line_items: [{ price: input.priceId, quantity: 1 }],
    payment_method_options: { card: { request_three_d_secure: "any" } },
    payment_intent_data: {
      description: CLOUD_INTRO_RECEIPT_DESCRIPTION,
      statement_descriptor_suffix: CLOUD_INTRO_STATEMENT_SUFFIX,
      metadata,
      // Only the buyer's "continue on Plus" choice keeps the card.
      ...(input.renewOnPlus ? { setup_future_usage: "off_session" as const } : {}),
    },
    client_reference_id: input.stackUserId,
    metadata,
    ...(input.customerId
      ? { customer: input.customerId }
      : { customer_creation: "always" as const, ...(input.email ? { customer_email: input.email } : {}) }),
    success_url: `${input.origin}/dashboard/billing?welcome=${CLOUD_INTRO_CHECKOUT_PLAN}`,
    cancel_url: `${input.origin}/pricing?billing=cancelled`,
  };
}

let cachedPriceId: string | null = null;

/** The active one-time $1 Price behind the pass's lookup key, checked once per process. */
async function resolveCloudIntroPrice(client: CloudIntroCheckoutStripe): Promise<string> {
  if (cachedPriceId) return cachedPriceId;
  const prices = await client.prices.list({
    active: true,
    lookup_keys: [CLOUD_INTRO_PRICING_USD.lookupKey],
    limit: 1,
  });
  const price = prices.data[0];
  if (
    !price ||
    price.type !== "one_time" ||
    price.unit_amount !== CLOUD_INTRO_PRICING_USD.unitAmountCents ||
    price.currency !== CLOUD_INTRO_PRICING_USD.currency
  ) {
    throw new Error(`Stripe price lookup key is missing or not a one-time $1 price: ${CLOUD_INTRO_PRICING_USD.lookupKey}`);
  }
  cachedPriceId = price.id;
  return price.id;
}

/** Test seam: forget the cached Price id. */
export function resetCloudIntroPriceCacheForTests(): void {
  cachedPriceId = null;
}

async function personalCustomerId(stackUserId: string): Promise<string | null> {
  const [row] = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(and(eq(stripeCustomers.stackUserId, stackUserId), isNull(stripeCustomers.stackTeamId)))
    .limit(1);
  return row?.id ?? null;
}

function isAccountDeleting(user: CloudIntroAccountUser): boolean {
  const metadata = user.clientReadOnlyMetadata;
  return Boolean(
    metadata && typeof metadata === "object" && (metadata as Record<string, unknown>).cmuxAccountDeleting === true,
  );
}

function pricingRedirect(request: NextRequest, code: string): NextResponse {
  return NextResponse.redirect(new URL(`/pricing?billing=${code}`, requestOrigin(request)));
}
