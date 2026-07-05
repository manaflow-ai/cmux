import { NextRequest, NextResponse } from "next/server";
import { stackServerApp } from "../../../lib/stack";
import { validatedNativeCallbackScheme } from "../../../lib/native-callback";
import {
  PRO_PRODUCT_ID,
  TEAM_PRODUCT_ID,
  hasActiveProSubscription,
  resolveProPlanStatus,
  syncProPlanMetadata,
} from "../../../../services/billing/pro";
import { captureBillingError } from "../../../../services/errors";
import {
  isStripeBillingConfigured,
  resolveProPrice,
  stripe,
  type ProBillingInterval,
} from "../../../../services/billing/stripe";

export const dynamic = "force-dynamic";

// One-click upgrade entrypoint. Signed-out visitors become anonymous Stack
// users first, then go straight to the hosted purchase page. Stack keeps the
// product grant attached to that anonymous user until the buyer completes
// account setup with an email.
export async function GET(request: NextRequest) {
  if (!stackServerApp) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", request.url));
  }

  const plan = checkoutPlan(request.nextUrl.searchParams.get("plan"));
  if (!plan) {
    return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", request.url));
  }

  if (plan === "pro" && isStripeBillingConfigured()) {
    return stripeProCheckout(request);
  }

  return legacyStackCheckout(request, plan);
}

async function stripeProCheckout(request: NextRequest) {
  const user =
    (await stackServerApp!.getUser({ or: "return-null" })) ??
    (await stackServerApp!.getUser({ or: "anonymous" }));

  const status = await resolveProPlanStatus(user);
  if (status.isPro) {
    await syncProPlanMetadata(user, true);
    return NextResponse.redirect(new URL("/pricing?welcome=active", request.url));
  }

  const scheme = validatedNativeCallbackScheme(
    request.nextUrl.searchParams.get("cmux_scheme"),
    request,
  );
  const interval = checkoutInterval(request.nextUrl.searchParams.get("interval"));
  const successUrl =
    `${request.nextUrl.origin}/api/billing/complete` +
    `?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=${encodeURIComponent(scheme)}`;
  const cancelUrl = new URL("/pricing?billing=cancelled", request.nextUrl.origin);
  const metadata = {
    stackUserId: user.id,
    plan: "pro",
    app: "cmux",
  };

  try {
    const session = await stripe().checkout.sessions.create({
      mode: "subscription",
      line_items: [
        {
          price: await resolveProPrice(interval),
          quantity: 1,
        },
      ],
      client_reference_id: user.id,
      metadata,
      subscription_data: { metadata },
      customer_email: !user.isAnonymous && user.primaryEmail ? user.primaryEmail : undefined,
      allow_promotion_codes: true,
      success_url: successUrl,
      cancel_url: cancelUrl.toString(),
    });
    if (!session.url) throw new Error("Stripe Checkout Session did not include a URL");
    return NextResponse.redirect(session.url);
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/checkout",
      plan: "pro",
      interval,
    });
    return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
  }
}

async function legacyStackCheckout(
  request: NextRequest,
  plan: "pro" | "team",
) {
  const user =
    (await stackServerApp!.getUser({ or: "return-null" })) ??
    (await stackServerApp!.getUser({ or: "anonymous" }));

  if (plan === "pro" && (await hasActiveProSubscription(user))) {
    await syncProPlanMetadata(user, true);
    return NextResponse.redirect(new URL("/pricing?welcome=active", request.url));
  }

  const returnUrl = new URL(
    plan === "pro" ? "/api/billing/confirm" : "/pricing?welcome=team",
    request.url,
  ).toString();
  let checkoutUrl: string;
  const productId = plan === "pro" ? PRO_PRODUCT_ID : TEAM_PRODUCT_ID;
  const customer = plan === "pro" ? user : await checkoutTeamCustomer(user);
  try {
    checkoutUrl = await customer.createCheckoutUrl({
      productId,
      returnUrl,
    });
  } catch (error) {
    if (plan === "pro" && isAlreadyGrantedError(error)) {
      await syncProPlanMetadata(user, true);
      return NextResponse.redirect(new URL("/pricing?welcome=active", request.url));
    }
    // return_url must be on a domain the Stack project trusts; previews and
    // local dev ports may not be. The purchase still works without it — the
    // buyer stays on the hosted receipt, and Pro state is picked up by the
    // read-time reconcile on VM create or the next visit to this route.
    try {
      checkoutUrl = await customer.createCheckoutUrl({ productId });
    } catch (retryError) {
      console.error("[Billing] createCheckoutUrl failed", error, retryError);
      return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
    }
  }
  return NextResponse.redirect(checkoutUrl);
}

type CheckoutTeamCustomer = {
  createCheckoutUrl(options: {
    productId: string;
    returnUrl?: string;
  }): Promise<string>;
};

type CheckoutTeamUser = {
  readonly selectedTeam?: CheckoutTeamCustomer | null;
  listTeams?(): Promise<CheckoutTeamCustomer[]>;
  createTeam?(data: { displayName: string }): Promise<CheckoutTeamCustomer>;
};

async function checkoutTeamCustomer(user: CheckoutTeamUser): Promise<CheckoutTeamCustomer> {
  if (user.selectedTeam) return user.selectedTeam;

  const teams = user.listTeams ? await user.listTeams() : [];
  if (teams.length === 1) return teams[0];
  if (teams.length > 1) return teams[0];

  if (!user.createTeam) {
    throw new Error("Stack Auth user cannot create a team checkout customer");
  }

  const team = await user.createTeam({ displayName: "cmux Team" });
  return team;
}

function checkoutPlan(raw: string | null): "pro" | "team" | null {
  if (!raw) return "pro";
  const plan = raw.trim().toLowerCase();
  if (plan === "pro" || plan === "team") return plan;
  return null;
}

function checkoutInterval(raw: string | null): ProBillingInterval {
  return raw === "month" ? "month" : "year";
}

function isAlreadyGrantedError(error: unknown): boolean {
  const text =
    error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /already.{0,20}granted/i.test(text);
}
