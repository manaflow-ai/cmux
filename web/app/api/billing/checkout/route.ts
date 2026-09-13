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
  MAX_PLAN_ID,
  GO_PLAN_ID,
  PRO_PLAN_ID,
  isStripePortalRecoverable,
  resolveProPlanStatus,
  stripeBillingStatusForTeam,
  stripeBillingStatusForUser,
  type PersonalPlanId,
} from "../../../../services/billing/pro";
import { captureBillingError } from "../../../../services/errors";
import {
  isStripeBillingConfigured,
  resolveMaxPrice,
  resolveGoPrice,
  resolveProPrice,
  resolveTeamPrice,
  stripe,
} from "../../../../services/billing/stripe";
import {
  CHECKOUT_BILLING_INTERVAL,
  type BillingInterval,
} from "../../../../services/billing/plans";
import { captureBillingCheckoutStarted } from "../../../../services/analytics/stripeBilling";
import {
  checkoutAttributionFromRequest,
  checkoutAttributionMetadata,
  forwardCheckoutAttribution,
  type CheckoutAttribution,
} from "../../../../services/analytics/checkoutAttribution";
import { parseNativeStackTokens, verifyRequest } from "../../../../services/vms/auth";
import { personalPortalSession } from "../../../../services/billing/personalPortal";
import { isGoPlanEnabled } from "../../../../services/billing/goPlanFlag";


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

// Action codes are stable across locales. The fallback action contains only
// invariant command syntax or a URL, which older CLI clients can still use.
function nativeCheckoutError(error: "unauthorized" | "invalid_plan" | "billing_unavailable" | "plan_unavailable") {
  const actions = {
    unauthorized: { actionCode: "auth_login", action: "cmux auth login", status: 401 },
    invalid_plan: { actionCode: "choose_plan", action: "cmux billing checkout --plan <go|pro|max>", status: 400 },
    billing_unavailable: { actionCode: "open_pricing", action: "https://cmux.com/pricing", status: 503 },
    plan_unavailable: { actionCode: "plan_unavailable", action: "cmux billing checkout --plan pro", status: 403 },
  } as const;
  const { status, ...action } = actions[error];
  return NextResponse.json({ error, ...action }, { status });
}

async function goPlanUnavailable(userID: string, plan: unknown): Promise<boolean> {
  return plan === "go" && !(await isGoPlanEnabled(userID));
}

/** Native/CLI checkout binds the purchaser to the app's authenticated account. */
export async function POST(request: NextRequest): Promise<NextResponse> {
  if (!parseNativeStackTokens(request)) return nativeCheckoutError("unauthorized");
  try {
    const user = await verifyRequest(request);
    if (!user || user.isAnonymous) return nativeCheckoutError("unauthorized");
    const body = await request.json();
    if (body?.plan !== "go" && body?.plan !== "max" && body?.plan !== "pro") return nativeCheckoutError("invalid_plan");
    if (await goPlanUnavailable(user.id, body.plan)) return nativeCheckoutError("plan_unavailable");
    const app = await checkoutStackServerApp();
    if (!app || !isStripeBillingConfigured()) return nativeCheckoutError("billing_unavailable");
    const attribution = checkoutAttributionFromRequest({ searchParams: new URLSearchParams({ cmux_source: "cli_billing_checkout", cmux_client: "cli" }) });
    const scheme = validatedNativeCallbackScheme(typeof body.cmux_scheme === "string" ? body.cmux_scheme : null, request);
    const response = await stripePersonalCheckout(request, app, body.plan, "month", scheme, attribution, user.id);
    const destination = response.headers.get("location");
    if (!destination) throw new Error("Checkout destination is unavailable");
    const url = new URL(destination);
    if (url.pathname === "/api/billing/portal" && url.origin === requestOrigin(request)) {
      const portal = await personalPortalSession({ userId: user.id, origin: requestOrigin(request), target: body.plan, attribution });
      return NextResponse.json({ url: portal.url, plan: body.plan, flow: "portal" });
    }
    if (url.searchParams.has("billing")) return nativeCheckoutError("billing_unavailable");
    return NextResponse.json({ url: destination, plan: body.plan, flow: url.searchParams.has("welcome") ? "already_active" : "checkout" });
  } catch (error) {
    captureBillingError(error, { route: "/api/billing/checkout", method: "POST" });
    return nativeCheckoutError("billing_unavailable");
  }
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
  const intervalError = unavailableIntervalResponse(request);
  if (intervalError) return intervalError;
  if (plan === GO_PLAN_ID && !(await isGoPlanEnabled())) {
    return NextResponse.redirect(new URL("/pricing?billing=plan_unavailable", requestOrigin(request)));
  }
  const interval = CHECKOUT_BILLING_INTERVAL;
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
  // Analytics only. Which page or app button opened checkout, and from which
  // build channel; see services/analytics/checkoutAttribution.ts.
  const attribution = checkoutAttributionFromRequest({
    searchParams: request.nextUrl.searchParams,
    referer: request.headers.get("referer"),
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

  if (!isStripeBillingConfigured()) {
    return NextResponse.redirect(new URL("/pricing?billing=unavailable", requestOrigin(request)));
  }

  if (plan === "go" || plan === "pro" || plan === "max") {
    return stripePersonalCheckout(
      request,
      stackServerApp,
      plan,
      interval,
      callbackScheme,
      attribution,
    );
  }
  if (plan === "team") {
    return stripeTeamCheckout(
      request,
      stackServerApp,
      interval,
      callbackScheme,
      attribution,
    );
  }
  // checkoutPlan only yields "go" | "pro" | "max" | "team" | null (null handled above);
  // this is unreachable but keeps GET returning a NextResponse.
  return NextResponse.redirect(new URL("/pricing?billing=invalid_plan", requestOrigin(request)));
}

/**
 * Personal checkout for Pro or Max. Both bill the same Stripe customer, so an
 * account with an active personal subscription never gets a second one: a
 * Pro subscriber asking for Max is sent to the Billing Portal's plan-switch
 * flow (Stripe prorates and confirms), and every other active or recoverable
 * state goes to the plain portal as before.
 */
// oxlint-disable-next-line complexity -- Checkout handles account deletion, recovery, attribution, and three personal plans at one billing boundary.
async function stripePersonalCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
  plan: PersonalPlanId,
  interval: BillingInterval,
  callbackScheme: string,
  attribution: CheckoutAttribution,
  authenticatedUserId?: string,
) {
  try {
    const user = authenticatedUserId ? await stackServerApp.getUser(authenticatedUserId) :
      (await stackServerApp.getUser({ or: "return-null" })) ??
      (await stackServerApp.getUser({ or: "anonymous" }));
    if (!user) throw new Error("Checkout account is unavailable");
    if (isAccountDeletionInProgress(user)) {
      return accountDeletionCheckoutRedirect(request);
    }
    // `or: "anonymous"` creates/returns the real Stack anonymous principal.
    // Keep that id as the source of truth for Stripe and checkout analytics.
    const stackUserId = checkoutPrincipalId(user.id, "user");

    const stripeBillingStatus = await stripeBillingStatusForUser(stackUserId);
    // Keep stale Upgrade links from opening a second subscription. Any
    // currently active row (even behind a newer canceled one) means the portal
    // is the right destination; the portal also recovers past-due/unpaid and
    // cancel-at-period-end states, but it cannot start a new subscription
    // after a terminal cancellation.
    if (stripeBillingStatus.hasRecurringSubscription || isStripePortalRecoverable(stripeBillingStatus)) {
      const portalURL = new URL("/api/billing/portal", requestOrigin(request));
      if (
        plan !== GO_PLAN_ID && stripeBillingStatus.hasActiveSubscription &&
        stripeBillingStatus.activePlanId !== plan
      ) {
        portalURL.searchParams.set("flow", "switch_plan");
        portalURL.searchParams.set("plan", plan);
      }
      forwardCheckoutAttribution(request.nextUrl.searchParams, portalURL);
      return NextResponse.redirect(portalURL);
    }
    const status = await resolveProPlanStatus(user, { stripeBillingStatus });
    if (status.isPro && (plan !== MAX_PLAN_ID || status.planId === MAX_PLAN_ID)) {
      return NextResponse.redirect(new URL("/pricing?welcome=active", requestOrigin(request)));
    }

    const successUrl =
      `${requestOrigin(request)}/api/billing/complete` +
      `?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=${encodeURIComponent(callbackScheme)}`;
    const cancelUrl = new URL("/pricing?billing=cancelled", requestOrigin(request));
    cancelUrl.searchParams.set("interval", interval);
    const metadata = {
      stackUserId,
      plan,
      app: "cmux",
      billingInterval: interval,
      nativeCallbackScheme: callbackScheme,
      ...checkoutAttributionMetadata(attribution),
    };

    const session = await stripe().checkout.sessions.create({
      mode: "subscription",
      line_items: [
        {
          price: plan === MAX_PLAN_ID
            ? await resolveMaxPrice()
            : plan === GO_PLAN_ID
              ? await resolveGoPrice()
              : await resolveProPrice(interval),
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
      plan,
      billingInterval: interval,
      attribution,
      signedIn: !user.isAnonymous,
      existingStripeCustomer: Boolean(stripeBillingStatus.customerId),
    }));
    return NextResponse.redirect(session.url);
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/checkout",
      plan,
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
  attribution: CheckoutAttribution,
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
      ...checkoutAttributionMetadata(attribution),
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
      attribution,
      signedIn: !user.isAnonymous,
      existingStripeCustomer: Boolean(stripeBillingStatus.customerId),
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

function checkoutPlan(raw: string | null): "go" | "pro" | "max" | "team" | null {
  if (!raw) return "pro";
  const plan = raw.trim().toLowerCase();
  if (plan === "go" || plan === "pro" || plan === "max" || plan === "team") return plan;
  return null;
}

function unavailableIntervalResponse(request: NextRequest): NextResponse | null {
  const raw = request.nextUrl.searchParams.get("interval");
  if (raw === null || raw === CHECKOUT_BILLING_INTERVAL) return null;
  const error = raw === "year" ? "annual_unavailable" : "invalid_plan";
  return NextResponse.redirect(new URL(`/pricing?billing=${error}`, requestOrigin(request)));
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
