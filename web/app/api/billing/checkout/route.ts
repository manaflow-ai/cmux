import type { StackServerApp } from "@stackframe/stack";
import { NextRequest, NextResponse } from "next/server";
import { eq } from "drizzle-orm";

import { validatedNativeCallbackScheme } from "../../../lib/native-callback";
import { isAppStoreDistributionMode } from "../../../lib/billing";
import { cloudDb } from "../../../../db/client";
import { stripeCustomers } from "../../../../db/schema";
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
  resolveTeamPrice,
  stripe,
  type ProBillingInterval,
} from "../../../../services/billing/stripe";

export const dynamic = "force-dynamic";

type CheckoutStackServerApp = StackServerApp<true>;

// One-click upgrade entrypoint. Signed-out visitors become anonymous Stack
// users first, then go straight to the hosted purchase page. Stack keeps the
// product grant attached to that anonymous user until the buyer completes
// account setup with an email.
export async function GET(request: NextRequest) {
  if (
    isAppStoreDistributionMode({
      cmux_distribution: request.nextUrl.searchParams.get("cmux_distribution"),
      cmux_ios_app_store: request.nextUrl.searchParams.get("cmux_ios_app_store"),
    })
  ) {
    return NextResponse.redirect(appStorePricingRedirect(request));
  }

  const stackServerApp = await checkoutStackServerApp();
  if (!stackServerApp) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", request.url));
  }

  const plan = checkoutPlan(request.nextUrl.searchParams.get("plan"));
  if (!plan) {
    return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", request.url));
  }

  if (plan === "pro" && isStripeBillingConfigured()) {
    return stripeProCheckout(request, stackServerApp);
  }
  if (plan === "team" && isStripeBillingConfigured()) {
    return stripeTeamCheckout(request, stackServerApp);
  }

  return legacyStackCheckout(request, stackServerApp, plan);
}

async function stripeProCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
) {
  const user =
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: "anonymous" }));

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

async function stripeTeamCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
) {
  const user =
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: "anonymous" }));
  const team = await checkoutTeamCustomer(user);
  const teamId = team.id;
  if (!teamId) {
    throw new Error("Stack team checkout customer is missing an id");
  }

  const scheme = validatedNativeCallbackScheme(
    request.nextUrl.searchParams.get("cmux_scheme"),
    request,
  );
  const successUrl =
    `${request.nextUrl.origin}/api/billing/complete` +
    `?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=${encodeURIComponent(scheme)}`;
  const cancelUrl = new URL("/pricing?billing=cancelled", request.nextUrl.origin);
  const metadata = {
    stackTeamId: teamId,
    plan: "team",
    app: "cmux",
  };

  try {
    const customerId = await stripeCustomerForTeam(team, user.id);
    const session = await stripe().checkout.sessions.create({
      mode: "subscription",
      line_items: [
        {
          price: await resolveTeamPrice(),
          quantity: await checkoutTeamSeatCount(team),
          adjustable_quantity: {
            enabled: true,
            minimum: 1,
          },
        },
      ],
      customer: customerId,
      client_reference_id: teamId,
      metadata,
      subscription_data: { metadata },
      allow_promotion_codes: true,
      success_url: successUrl,
      cancel_url: cancelUrl.toString(),
    });
    if (!session.url) throw new Error("Stripe Checkout Session did not include a URL");
    return NextResponse.redirect(session.url);
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/checkout",
      plan: "team",
      stackTeamId: teamId,
    });
    return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
  }
}

async function legacyStackCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
  plan: "pro" | "team",
) {
  const user =
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: "anonymous" }));

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
    // "Already granted" error text is only a hint — re-read the authoritative
    // subscription state before treating the buyer as Pro, so a lookalike
    // error message can never mint an entitlement.
    if (plan === "pro" && isAlreadyGrantedError(error)) {
      if (await hasActiveProSubscription(user)) {
        await syncProPlanMetadata(user, true);
        return NextResponse.redirect(new URL("/pricing?welcome=active", request.url));
      }
      // Stack refused the checkout as already-granted but the products read
      // does not show Pro yet (replication lag). The confirm route's bounded
      // poll settles it and syncs metadata from the verified state.
      return NextResponse.redirect(new URL("/api/billing/confirm", request.url));
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
  readonly id?: string;
  readonly displayName?: string | null;
  listUsers?(): Promise<readonly unknown[]>;
  createCheckoutUrl(options: {
    productId: string;
    returnUrl?: string;
  }): Promise<string>;
};

type CheckoutTeamUser = {
  readonly id: string;
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

async function stripeCustomerForTeam(
  team: CheckoutTeamCustomer,
  stackUserId: string,
): Promise<string> {
  if (!team.id) throw new Error("Stack team checkout customer is missing an id");
  const [existing] = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackTeamId, team.id))
    .limit(1);
  if (existing?.id) return existing.id;

  const customer = await stripe().customers.create({
    name: team.displayName?.trim() || "cmux Team",
    metadata: {
      stackTeamId: team.id,
      app: "cmux",
    },
  });

  try {
    await cloudDb()
      .insert(stripeCustomers)
      .values({
        id: customer.id,
        stackUserId,
        stackTeamId: team.id,
        email: null,
      });
    return customer.id;
  } catch (error) {
    if (!isStackTeamUniqueConflict(error)) throw error;
    const [raceWinner] = await cloudDb()
      .select({ id: stripeCustomers.id })
      .from(stripeCustomers)
      .where(eq(stripeCustomers.stackTeamId, team.id))
      .limit(1);
    if (raceWinner?.id) return raceWinner.id;
    throw error;
  }
}

async function checkoutTeamSeatCount(team: CheckoutTeamCustomer): Promise<number> {
  if (!team.listUsers) return 1;
  const users = await team.listUsers();
  return Math.max(1, users.length);
}

function checkoutPlan(raw: string | null): "pro" | "team" | null {
  if (!raw) return "pro";
  const plan = raw.trim().toLowerCase();
  if (plan === "pro" || plan === "team") return plan;
  return null;
}

function checkoutInterval(raw: string | null): ProBillingInterval {
  return raw === "year" ? "year" : "month";
}

async function checkoutStackServerApp(): Promise<CheckoutStackServerApp | null> {
  const { getStackServerApp, isStackConfigured } = await import("../../../lib/stack");
  if (!isStackConfigured()) return null;
  return getStackServerApp();
}

function appStorePricingRedirect(request: NextRequest): URL {
  const redirectURL = new URL("/app-pricing", request.url);
  redirectURL.searchParams.set("cmux_app", "1");
  redirectURL.searchParams.set("cmux_distribution", "appstore");
  redirectURL.searchParams.set("billing", "unavailable");

  for (const key of ["cmux_scheme", "appearance", "background"]) {
    const value = request.nextUrl.searchParams.get(key);
    if (value) redirectURL.searchParams.set(key, value);
  }

  return redirectURL;
}

function isAlreadyGrantedError(error: unknown): boolean {
  const text =
    error instanceof Error ? `${error.name} ${error.message}` : String(error);
  return /already.{0,20}granted/i.test(text);
}

function isStackTeamUniqueConflict(error: unknown): boolean {
  const cause = (error as { cause?: unknown } | null)?.cause;
  const candidate = (cause ?? error) as { code?: string; constraint?: string } | null;
  if (
    candidate?.code === "23505" &&
    candidate.constraint === "stripe_customers_stack_team_id_unique"
  ) {
    return true;
  }
  const text = error instanceof Error ? error.message : String(error);
  return /stripe_customers_stack_team_id_unique/.test(text);
}
