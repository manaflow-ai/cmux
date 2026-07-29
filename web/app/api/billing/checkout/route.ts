import type { StackServerApp } from "@stackframe/stack";
import { NextRequest, NextResponse } from "next/server";
import { eq } from "drizzle-orm";

import { validatedNativeCallbackScheme } from "../../../lib/native-callback";
import {
  appStorePricingUnavailableURL,
  isAppStoreDistributionMode,
} from "../../../lib/billing";
import { cloudDb } from "../../../../db/client";
import { stripeCustomers } from "../../../../db/schema";
import {
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
// users first, then go straight to Stripe Checkout.
//
// Default: a browser navigation that 302s to Stripe (works with no JS).
// With `?format=json`: run the same logic, then hand the client the resolved
// destination as `{ url }` so a button can show a spinner and redirect itself
// instead of flashing this route's blank page. The url is whatever we would
// have redirected to — the Stripe Checkout URL on success, or a /pricing state
// URL otherwise — so the client just navigates to it either way.
export async function GET(request: NextRequest): Promise<NextResponse> {
  const response = await resolveCheckout(request);
  if (request.nextUrl.searchParams.get("format") !== "json") return response;
  const location = response.headers.get("location");
  return NextResponse.json({
    url: location ?? new URL("/pricing?billing=error", request.url).toString(),
  });
}

async function resolveCheckout(request: NextRequest): Promise<NextResponse> {
  if (
    isAppStoreDistributionMode({
      cmux_distribution: request.nextUrl.searchParams.get("cmux_distribution"),
      cmux_ios_app_store: request.nextUrl.searchParams.get("cmux_ios_app_store"),
    })
  ) {
    return NextResponse.redirect(appStorePricingUnavailableURL(request.nextUrl));
  }

  const stackServerApp = await checkoutStackServerApp();
  if (!stackServerApp) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", request.url));
  }

  const plan = checkoutPlan(request.nextUrl.searchParams.get("plan"));
  if (!plan) {
    return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", request.url));
  }

  if (!isStripeBillingConfigured()) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", request.url));
  }

  if (plan === "pro") {
    return stripeProCheckout(request, stackServerApp);
  }
  if (plan === "team") {
    return stripeTeamCheckout(request, stackServerApp);
  }
  // checkoutPlan only yields "pro" | "team" | null (null handled above); this is
  // unreachable but keeps GET returning a NextResponse instead of possibly-undefined.
  return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", request.url));
}

async function stripeProCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
) {
  const user =
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: "anonymous" }));
  if (isAccountDeletionInProgress(user)) {
    return accountDeletionCheckoutRedirect(request);
  }

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
  if (isAccountDeletionInProgress(user)) {
    return accountDeletionCheckoutRedirect(request);
  }
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

function accountDeletionCheckoutRedirect(request: NextRequest) {
  return NextResponse.redirect(
    new URL("/pricing?billing=account_deletion_in_progress", request.url),
  );
}

function isAccountDeletionInProgress(user: { readonly clientReadOnlyMetadata?: unknown }): boolean {
  const metadata = user.clientReadOnlyMetadata;
  return Boolean(
    metadata &&
      typeof metadata === "object" &&
      !Array.isArray(metadata) &&
      (metadata as Record<string, unknown>).cmuxAccountDeleting === true
  );
}

type CheckoutTeamCustomer = {
  readonly id?: string;
  readonly displayName?: string | null;
  listUsers?(): Promise<readonly unknown[]>;
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
