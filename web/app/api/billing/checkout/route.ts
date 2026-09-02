import type { StackServerApp } from "@stackframe/stack";
import { after, NextRequest, NextResponse } from "next/server";
import { eq } from "drizzle-orm";

import { validatedNativeCallbackScheme } from "../../../lib/native-callback";
import { requestOrigin, requestWithOrigin } from "../../../lib/request-origin";
import {
  CHECKOUT_RELAY_EXPIRES_PARAM,
  CHECKOUT_RELAY_SIGNATURE_PARAM,
  appPricingCheckoutRelayURL,
  appStorePricingUnavailableURL,
  isProtectedAppPricingRelayScheme,
  isAppStoreDistributionMode,
  verifiedAppPricingRelayScheme,
} from "../../../lib/billing";
import { cloudDb } from "../../../../db/client";
import { stripeCustomers } from "../../../../db/schema";
import {
  isStripePortalRecoverable,
  resolveProPlanStatus,
  stripeBillingStatusForTeam,
  stripeBillingStatusForUser,
} from "../../../../services/billing/pro";
import { captureBillingError } from "../../../../services/errors";
import {
  isStripeBillingConfigured,
  resolveProPrice,
  resolveTeamPrice,
  stripe,
} from "../../../../services/billing/stripe";
import {
  billingInterval,
  type BillingInterval,
} from "../../../../services/billing/plans";
import { captureBillingCheckoutStarted } from "../../../../services/analytics/stripeBilling";


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
    url: location ?? new URL("/pricing?billing=error", requestOrigin(request)).toString(),
  });
}

async function resolveCheckout(request: NextRequest): Promise<NextResponse> {
  if (
    isAppStoreDistributionMode({
      cmux_distribution: request.nextUrl.searchParams.get("cmux_distribution"),
      cmux_ios_app_store: request.nextUrl.searchParams.get("cmux_ios_app_store"),
    })
  ) {
    return NextResponse.redirect(appStorePricingUnavailableURL(requestWithOrigin(request).nextUrl));
  }

  const plan = checkoutPlan(request.nextUrl.searchParams.get("plan"));
  const interval = checkoutBillingInterval(
    request.nextUrl.searchParams.get("interval"),
  );
  const rawCallbackScheme = request.nextUrl.searchParams.get("cmux_scheme");
  const verifiedRelayScheme = verifiedAppPricingRelayScheme(request.nextUrl);
  const hasRelayAssertion =
    request.nextUrl.searchParams.has(CHECKOUT_RELAY_EXPIRES_PARAM) ||
    request.nextUrl.searchParams.has(CHECKOUT_RELAY_SIGNATURE_PARAM);
  if (
    isProtectedAppPricingRelayScheme(rawCallbackScheme) &&
    !verifiedRelayScheme &&
    hasRelayAssertion
  ) {
    return NextResponse.redirect(
      new URL("/pricing?billing=invalid_relay", requestOrigin(request)),
    );
  }
  const callbackScheme =
    verifiedRelayScheme ??
    validatedNativeCallbackScheme(
      rawCallbackScheme,
      request,
    );
  const configuredRelayURL = appPricingCheckoutRelayURL(request.nextUrl, {
    plan,
    interval,
    cmuxScheme: callbackScheme,
  });
  if (configuredRelayURL) {
    return NextResponse.redirect(configuredRelayURL);
  }

  const stackServerApp = await checkoutStackServerApp();
  if (!stackServerApp) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", requestOrigin(request)));
  }

  if (!plan) {
    return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", requestOrigin(request)));
  }
  if (!interval) {
    return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", requestOrigin(request)));
  }

  if (!isStripeBillingConfigured()) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", requestOrigin(request)));
  }

  if (plan === "pro") {
    return stripeProCheckout(
      request,
      stackServerApp,
      interval,
      callbackScheme,
    );
  }
  if (plan === "team") {
    return stripeTeamCheckout(
      request,
      stackServerApp,
      interval,
      callbackScheme,
    );
  }
  // checkoutPlan only yields "pro" | "team" | null (null handled above); this is
  // unreachable but keeps GET returning a NextResponse instead of possibly-undefined.
  return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", requestOrigin(request)));
}

async function stripeProCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
  interval: BillingInterval,
  callbackScheme: string,
) {
  try {
    const user =
      (await stackServerApp.getUser({ or: "return-null" })) ??
      (await stackServerApp.getUser({ or: "anonymous" }));
    if (isAccountDeletionInProgress(user)) {
      return accountDeletionCheckoutRedirect(request);
    }
    // `or: "anonymous"` creates/returns the real Stack anonymous principal.
    // Keep that id as the source of truth for Stripe and checkout analytics.
    const stackUserId = checkoutPrincipalId(user.id, "user");

    const stripeBillingStatus = await stripeBillingStatusForUser(stackUserId);
    const status = await resolveProPlanStatus(user, { stripeBillingStatus });
    // Keep stale Upgrade links from opening a second subscription. Any
    // currently active row (even behind a newer canceled one) means the portal
    // is the right destination; the portal also recovers past-due/unpaid and
    // cancel-at-period-end states, but it cannot start a new subscription
    // after a terminal cancellation.
    if (stripeBillingStatus.hasActiveSubscription || isStripePortalRecoverable(stripeBillingStatus)) {
      return NextResponse.redirect(new URL("/api/billing/portal", requestOrigin(request)));
    }
    if (status.isPro) {
      return NextResponse.redirect(new URL("/pricing?welcome=active", requestOrigin(request)));
    }

    const successUrl =
      `${requestOrigin(request)}/api/billing/complete` +
      `?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=${encodeURIComponent(callbackScheme)}`;
    const cancelUrl = new URL("/pricing?billing=cancelled", requestOrigin(request));
    cancelUrl.searchParams.set("interval", interval);
    const metadata = {
      stackUserId,
      plan: "pro",
      app: "cmux",
      billingInterval: interval,
      nativeCallbackScheme: callbackScheme,
    };

    const session = await stripe().checkout.sessions.create({
      mode: "subscription",
      line_items: [
        {
          price: await resolveProPrice(interval),
          quantity: 1,
        },
      ],
      client_reference_id: stackUserId,
      metadata,
      subscription_data: { metadata },
      customer: stripeBillingStatus.customerId ?? undefined,
      customer_email: stripeBillingStatus.customerId
        ? undefined
        : !user.isAnonymous && user.primaryEmail
          ? user.primaryEmail
          : undefined,
      allow_promotion_codes: true,
      success_url: successUrl,
      cancel_url: cancelUrl.toString(),
    });
    if (!usableCheckoutSession(session)) {
      throw new Error("Stripe Checkout Session did not include an id and URL");
    }
    deferCheckoutAnalytics(() => captureBillingCheckoutStarted({
      sessionId: session.id,
      subject: { scope: "user", stackUserId },
      plan: "pro",
      billingInterval: interval,
    }));
    return NextResponse.redirect(session.url);
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/checkout",
      plan: "pro",
      interval,
    });
    return NextResponse.redirect(new URL("/pricing?billing=error", requestOrigin(request)));
  }
}

async function stripeTeamCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
  interval: BillingInterval,
  callbackScheme: string,
) {
  let teamId: string | undefined;
  try {
    const user =
      (await stackServerApp.getUser({ or: "return-null" })) ??
      (await stackServerApp.getUser({ or: "anonymous" }));
    if (isAccountDeletionInProgress(user)) {
      return accountDeletionCheckoutRedirect(request);
    }
    const stackUserId = checkoutPrincipalId(user.id, "user");
    const team = await checkoutTeamCustomer(user);
    const resolvedTeamId = checkoutPrincipalId(team.id, "team");
    teamId = resolvedTeamId;

    const stripeBillingStatus = await stripeBillingStatusForTeam(resolvedTeamId);
    // Same rule as personal checkout: an already-paying team manages billing
    // in the portal; checkout would create a duplicate subscription.
    if (stripeBillingStatus.hasActiveSubscription || isStripePortalRecoverable(stripeBillingStatus)) {
      const portalURL = new URL("/api/billing/portal", requestOrigin(request));
      portalURL.searchParams.set("scope", "team");
      return NextResponse.redirect(portalURL);
    }

    const successUrl =
      `${requestOrigin(request)}/api/billing/complete` +
      `?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=${encodeURIComponent(callbackScheme)}`;
    const cancelUrl = new URL("/pricing?billing=cancelled", requestOrigin(request));
    cancelUrl.searchParams.set("interval", interval);
    const metadata = {
      stackTeamId: resolvedTeamId,
      plan: "team",
      app: "cmux",
      billingInterval: interval,
      nativeCallbackScheme: callbackScheme,
    };

    const customerId =
      stripeBillingStatus.customerId ?? await stripeCustomerForTeam(team, stackUserId);
    const session = await stripe().checkout.sessions.create({
      mode: "subscription",
      line_items: [
        {
          price: await resolveTeamPrice(interval),
          quantity: await checkoutTeamSeatCount(team),
          adjustable_quantity: {
            enabled: true,
            minimum: 1,
          },
        },
      ],
      customer: customerId,
      client_reference_id: resolvedTeamId,
      metadata,
      subscription_data: { metadata },
      allow_promotion_codes: true,
      success_url: successUrl,
      cancel_url: cancelUrl.toString(),
    });
    if (!usableCheckoutSession(session)) {
      throw new Error("Stripe Checkout Session did not include an id and URL");
    }
    deferCheckoutAnalytics(() => captureBillingCheckoutStarted({
      sessionId: session.id,
      subject: { scope: "team", stackTeamId: resolvedTeamId },
      plan: "team",
      billingInterval: interval,
    }));
    return NextResponse.redirect(session.url);
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/checkout",
      plan: "team",
      interval,
      stackTeamId: teamId,
    });
    return NextResponse.redirect(new URL("/pricing?billing=error", requestOrigin(request)));
  }
}

function accountDeletionCheckoutRedirect(request: NextRequest) {
  return NextResponse.redirect(
    new URL("/pricing?billing=account_deletion_in_progress", requestOrigin(request)),
  );
}

function checkoutPrincipalId(value: unknown, kind: "user" | "team"): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`Stack ${kind} checkout principal is missing an id`);
  }
  return value;
}

function usableCheckoutSession(
  value: unknown,
): value is { readonly id: string; readonly url: string } {
  if (!value || typeof value !== "object") return false;
  const session = value as { readonly id?: unknown; readonly url?: unknown };
  return (
    typeof session.id === "string" &&
    session.id.trim().length > 0 &&
    typeof session.url === "string" &&
    session.url.trim().length > 0
  );
}

function deferCheckoutAnalytics(task: () => Promise<void>): void {
  try {
    after(task);
  } catch {
    // Unit tests and non-Next callers have no request work store. Analytics is
    // best effort and must never turn a valid Checkout session into an error.
    void task();
  }
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

function checkoutBillingInterval(raw: string | null): BillingInterval | null {
  if (raw === null) return billingInterval(raw);
  return raw === "month" || raw === "year" ? raw : null;
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
