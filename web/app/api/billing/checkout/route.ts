import type { StackServerApp } from "@hexclave/next";
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
import { vaultSignInHref } from "../../../lib/vault-auth";
import { captureServerEvent } from "../../../../services/analytics/serverEvents";
import { checkoutAttributionProperties } from "../../../../services/analytics/checkoutAttribution";
import {
  TEAM_ADMIN_PERMISSION,
  explicitTeamId,
  resolveTeamBillingAccess,
  teamBillingAccessStatus,
  type TeamBillingAccessError,
  type TeamBillingAccessUser,
} from "../../../../services/billing/teamBillingAccess";
import { teamPortalSession } from "../../../../services/billing/teamPortal";


type CheckoutStackServerApp = StackServerApp<true>;

// Every purchase entrypoint authenticates before looking up billing or
// creating a Stripe object. The selected plan survives the sign-in return.
//
// Default: a browser navigation that 302s to Stripe (works with no JS).
// With `?format=json`: run the same logic, then hand the client the resolved
// destination as `{ url }` so a button can show a spinner and redirect itself
// instead of flashing this route's blank page. The url is whatever we would
// have redirected to — the Stripe Checkout URL on success, or a /pricing state
// URL otherwise — so the client just navigates to it either way.
export async function GET(request: NextRequest): Promise<NextResponse> {
  const response = await resolveCheckout(request);
  const location = response.headers.get("location");
  const isRefusal = !location && response.status >= 400;
  if (request.nextUrl.searchParams.get("format") !== "json") {
    return isRefusal ? await teamRefusalBillingRedirect(request, response) : response;
  }
  // Explicit-team refusals are JSON errors with a status, not destinations.
  if (isRefusal) return response;
  return NextResponse.json({
    url: location ?? new URL("/pricing?billing=error", requestOrigin(request)).toString(),
  });
}

/**
 * A browser navigation must not land on raw JSON: an explicit-team refusal
 * returns to the dashboard billing view with a banner code, like the portal
 * and subscription routes. The team stays selected only when the caller is a
 * member of it (admin required, authorization unavailable).
 */
async function teamRefusalBillingRedirect(request: NextRequest, refusal: NextResponse): Promise<NextResponse> {
  const body = await refusal.json().catch(() => null) as { error?: unknown } | null;
  const code = typeof body?.error === "string" ? body.error : "error";
  const url = new URL("/dashboard/billing", requestOrigin(request));
  const teamId = explicitTeamId(request.nextUrl.searchParams.get("teamId"));
  if (teamId && (code === "team_admin_required" || code === "authorization_unavailable")) {
    url.searchParams.set("team", teamId);
  }
  url.searchParams.set("billing", code);
  return NextResponse.redirect(url);
}

// Action codes are stable across locales. The fallback action contains only
// invariant command syntax or a URL, which older CLI clients can still use.
type NativeCheckoutError =
  | "unauthorized"
  | "invalid_plan"
  | "billing_unavailable"
  | "plan_unavailable"
  | "team_id_required"
  | TeamBillingAccessError;

const NATIVE_CHECKOUT_ERRORS = {
  unauthorized: { actionCode: "auth_login", action: "cmux auth login", status: 401 },
  invalid_plan: { actionCode: "choose_plan", action: "cmux billing checkout --plan <go|pro|max>", status: 400 },
  billing_unavailable: { actionCode: "open_pricing", action: "https://cmux.com/pricing", status: 503 },
  plan_unavailable: { actionCode: "plan_unavailable", action: "cmux billing checkout --plan pro", status: 403 },
  team_id_required: { actionCode: "open_teams", action: "https://cmux.com/dashboard/teams", status: 400 },
  // The personal entry routes to Pro/Max; Team checkout needs a real team.
  personal_team_not_upgradable_to_team: {
    actionCode: "choose_plan",
    action: "cmux billing checkout --plan <go|pro|max>",
    status: teamBillingAccessStatus("personal_team_not_upgradable_to_team"),
  },
  team_not_found: { actionCode: "open_teams", action: "https://cmux.com/dashboard/teams", status: teamBillingAccessStatus("team_not_found") },
  team_admin_required: { actionCode: "ask_team_admin", action: "https://cmux.com/dashboard/teams", status: teamBillingAccessStatus("team_admin_required") },
  authorization_unavailable: { actionCode: "retry", action: "https://cmux.com/dashboard/billing", status: teamBillingAccessStatus("authorization_unavailable") },
} as const satisfies Record<NativeCheckoutError, { actionCode: string; action: string; status: number }>;

function nativeCheckoutError(error: NativeCheckoutError) {
  const { status, ...action } = NATIVE_CHECKOUT_ERRORS[error];
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
    const plan = nativeCheckoutPlan(body);
    if (plan === "team") return await nativeTeamCheckout(request, user.id, body);
    if (!plan) return nativeCheckoutError("invalid_plan");
    if (await goPlanUnavailable(user.id, plan)) return nativeCheckoutError("plan_unavailable");
    const app = await checkoutStackServerApp();
    if (!app || !isStripeBillingConfigured()) return nativeCheckoutError("billing_unavailable");
    const attribution = nativeCheckoutAttribution();
    const scheme = validatedNativeCallbackScheme(typeof body.cmux_scheme === "string" ? body.cmux_scheme : null, request);
    const response = await stripePersonalCheckout(request, app, plan, "month", scheme, attribution, user.id);
    const destination = response.headers.get("location");
    if (!destination) throw new Error("Checkout destination is unavailable");
    const url = new URL(destination);
    if (url.pathname === "/api/billing/portal" && url.origin === requestOrigin(request)) {
      const portal = await personalPortalSession({ userId: user.id, origin: requestOrigin(request), target: plan, attribution });
      return NextResponse.json({ url: portal.url, plan: plan, flow: "portal" });
    }
    if (url.searchParams.has("billing")) return nativeCheckoutError("billing_unavailable");
    return NextResponse.json({ url: destination, plan: plan, flow: url.searchParams.has("welcome") ? "already_active" : "checkout" });
  } catch (error) {
    captureBillingError(error, { route: "/api/billing/checkout", method: "POST" });
    return nativeCheckoutError("billing_unavailable");
  }
}

function nativeCheckoutPlan(body: unknown): PersonalPlanId | "team" | null {
  const plan = body && typeof body === "object" ? (body as { plan?: unknown }).plan : null;
  return plan === "go" || plan === "pro" || plan === "max" || plan === "team" ? plan : null;
}

function nativeCheckoutAttribution(): CheckoutAttribution {
  return checkoutAttributionFromRequest({ searchParams: new URLSearchParams({ cmux_source: "cli_billing_checkout", cmux_client: "cli" }) });
}

/**
 * Native Team checkout is always explicit: the app names the team, and the
 * caller must be its admin. There is no implicit-team POST to stay
 * compatible with, since POST never accepted `team` before.
 */
async function nativeTeamCheckout(
  request: NextRequest,
  userId: string,
  body: { readonly teamId?: unknown; readonly cmux_scheme?: unknown },
): Promise<NextResponse> {
  const teamId = explicitTeamId(body.teamId);
  if (!teamId) return nativeCheckoutError("team_id_required");
  const app = await checkoutStackServerApp();
  if (!app || !isStripeBillingConfigured()) return nativeCheckoutError("billing_unavailable");
  const scheme = validatedNativeCallbackScheme(typeof body.cmux_scheme === "string" ? body.cmux_scheme : null, request);
  const response = await stripeTeamCheckout(request, app, "month", scheme, nativeCheckoutAttribution(), {
    teamId,
    authenticatedUserId: userId,
  });
  const destination = response.headers.get("location");
  if (!destination) return response;
  const url = new URL(destination);
  if (url.pathname === "/api/billing/portal" && url.origin === requestOrigin(request)) {
    const portal = await teamPortalSession({ teamId, origin: requestOrigin(request) });
    if (!portal) return nativeCheckoutError("billing_unavailable");
    return NextResponse.json({ url: portal.url, plan: "team", teamId, flow: "portal" });
  }
  if (url.searchParams.has("billing")) return nativeCheckoutError("billing_unavailable");
  return NextResponse.json({ url: destination, plan: "team", teamId, flow: "checkout" });
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
  const requestedTeamId = explicitTeamId(request.nextUrl.searchParams.get("teamId"));
  if (configuredRelayURL) {
    // The relay target runs this same route, which re-authorizes the team, so
    // the unsigned team id only selects; it never grants access.
    if (plan === "team" && requestedTeamId) configuredRelayURL.searchParams.set("teamId", requestedTeamId);
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
      { teamId: requestedTeamId },
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
      await stackServerApp.getUser({ or: "return-null" });
    if (!user || user.isAnonymous) return checkoutSignInRedirect(request);
    if (plan === GO_PLAN_ID && !(await isGoPlanEnabled(user.id))) {
      return NextResponse.redirect(new URL("/pricing?billing=plan_unavailable", requestOrigin(request)));
    }
    if (isAccountDeletionInProgress(user)) {
      return accountDeletionCheckoutRedirect(request);
    }
    // Billing and analytics share the verified account identifier.
    const stackUserId = checkoutPrincipalId(user.id, "user");
    captureCheckoutAuthenticated(request, user.id, plan, attribution);

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
      captureCheckoutDecision(user.id, plan, stripeBillingStatus.activePlanId,
        portalURL.searchParams.has("flow") ? "switch_plan" : "manage_billing", attribution);
      return NextResponse.redirect(portalURL);
    }
    const status = await resolveProPlanStatus(user, { stripeBillingStatus });
    if (status.isPro && (plan !== MAX_PLAN_ID || status.planId === MAX_PLAN_ID)) {
      captureCheckoutDecision(user.id, plan, status.planId, "already_active", attribution);
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

type TeamCheckoutTarget = {
  /** Explicit team from `?teamId=` or the POST body; null keeps legacy resolution. */
  readonly teamId: string | null;
  /** Set by the native POST path, which already verified the app's tokens. */
  readonly authenticatedUserId?: string;
};

async function stripeTeamCheckout(
  request: NextRequest,
  stackServerApp: CheckoutStackServerApp,
  interval: BillingInterval,
  callbackScheme: string,
  attribution: CheckoutAttribution,
  target: TeamCheckoutTarget,
) {
  let teamId: string | undefined;
  try {
    const user = target.authenticatedUserId
      ? await stackServerApp.getUser(target.authenticatedUserId)
      : await stackServerApp.getUser({ or: "return-null" });
    if (!user || user.isAnonymous) return checkoutSignInRedirect(request);
    if (isAccountDeletionInProgress(user)) {
      return accountDeletionCheckoutRedirect(request);
    }
    const stackUserId = checkoutPrincipalId(user.id, "user");
    captureCheckoutAuthenticated(request, user.id, "team", attribution);
    const resolved = await teamCheckoutCustomer(user, target.teamId);
    if (!resolved.ok) return nativeCheckoutError(resolved.error);
    const team = resolved.team;
    const resolvedTeamId = checkoutPrincipalId(team.id, "team");
    teamId = resolvedTeamId;

    const stripeBillingStatus = await stripeBillingStatusForTeam(resolvedTeamId);
    // Same rule as personal checkout: an already-paying team manages billing
    // in the portal; checkout would create a duplicate subscription.
    if (stripeBillingStatus.hasRecurringSubscription || isStripePortalRecoverable(stripeBillingStatus)) {
      const portalURL = new URL("/api/billing/portal", requestOrigin(request));
      portalURL.searchParams.set("scope", "team");
      if (target.teamId) portalURL.searchParams.set("teamId", resolvedTeamId);
      forwardCheckoutAttribution(request.nextUrl.searchParams, portalURL);
      captureCheckoutDecision(user.id, "team", "team", "manage_billing", attribution);
      return NextResponse.redirect(portalURL);
    }

    const successUrl =
      `${requestOrigin(request)}/api/billing/complete` +
      `?session_id={CHECKOUT_SESSION_ID}&cmux_scheme=${encodeURIComponent(callbackScheme)}`;
    const cancelUrl = new URL("/pricing?billing=cancelled", requestOrigin(request));
    cancelUrl.searchParams.set("interval", interval);
    const metadata = {
      stackTeamId: resolvedTeamId,
      // The purchasing admin, for support and audit. Fulfillment stays team-scoped.
      stackUserId,
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

/** Preserve only a first-party checkout return; JSON fetches resume as navigation. */
function checkoutSignInRedirect(request: NextRequest): NextResponse {
  const returnURL = new URL(request.url);
  returnURL.searchParams.delete("format");
  returnURL.searchParams.set("cmux_after_sign_in", "1");
  return NextResponse.redirect(new URL(
    vaultSignInHref(`${returnURL.pathname}${returnURL.search}`),
    requestOrigin(request),
  ));
}

function captureCheckoutAuthenticated(request: NextRequest, userId: string, plan: string, attribution: CheckoutAttribution): void {
  void captureServerEvent({
    event: "cmux_billing_checkout_authenticated",
    distinctId: userId,
    properties: { plan, resumed_after_sign_in: request.nextUrl.searchParams.get("cmux_after_sign_in") === "1",
      ...checkoutAttributionProperties(attribution) },
  });
}

function captureCheckoutDecision(
  userId: string,
  plan: string,
  currentPlan: string | null,
  decision: "switch_plan" | "manage_billing" | "already_active",
  attribution: CheckoutAttribution,
): void {
  void captureServerEvent({
    event: "cmux_billing_checkout_routed",
    distinctId: userId,
    properties: { requested_plan: plan, current_plan: currentPlan, decision,
      billing_interval: "month", ...checkoutAttributionProperties(attribution) },
  });
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
  delete?(): Promise<void>;
};

type CheckoutTeamUser = TeamBillingAccessUser & {
  readonly id: string;
  readonly selectedTeam?: CheckoutTeamCustomer | null;
  listTeams?(): Promise<CheckoutTeamCustomer[]>;
  createTeam?(data: { displayName: string }): Promise<CheckoutTeamCustomer>;
  grantPermission?(team: CheckoutTeamCustomer, permissionId: string): Promise<void>;
};

type TeamCheckoutCustomerResult =
  | { readonly ok: true; readonly team: CheckoutTeamCustomer }
  | { readonly ok: false; readonly error: TeamBillingAccessError };

async function teamCheckoutCustomer(
  user: CheckoutTeamUser,
  teamId: string | null,
): Promise<TeamCheckoutCustomerResult> {
  if (!teamId) return legacyCheckoutTeamCustomer(user);
  const access = await resolveTeamBillingAccess(user, teamId, { requireAdmin: true });
  return access.ok ? { ok: true, team: access.team } : access;
}

/**
 * Implicit team resolution for macOS clients that predate explicit team ids:
 * the selected team, else the first team, else a new "cmux Team". An existing
 * team needs the caller to be its admin, as an explicit team id does.
 */
async function legacyCheckoutTeamCustomer(user: CheckoutTeamUser): Promise<TeamCheckoutCustomerResult> {
  const existing = user.selectedTeam ?? (user.listTeams ? await user.listTeams() : [])[0];
  if (existing?.id) {
    const access = await resolveTeamBillingAccess(user, existing.id, { requireAdmin: true });
    return access.ok ? { ok: true, team: existing } : access;
  }

  if (!user.createTeam) {
    throw new Error("Stack Auth user cannot create a team checkout customer");
  }

  const team = await user.createTeam({ displayName: "cmux Team" });
  await grantCreatorTeamAdmin(user, team);
  return { ok: true, team };
}

/**
 * Stack's creator default does not make the creator a cmux admin, and the
 * buyer must be able to manage billing later through the explicit,
 * admin-only paths. Same contract as services/teams createTeamForUser: a team
 * whose admin grant failed is deleted again and checkout fails, rather than
 * leaving an unmanageable team that later implicit checkouts would pick.
 * This grants through the already-loaded user instead of services/teams
 * grantTeamAdmin, which needs the Stack app and a second user lookup.
 */
async function grantCreatorTeamAdmin(user: CheckoutTeamUser, team: CheckoutTeamCustomer): Promise<void> {
  try {
    if (typeof user.grantPermission !== "function") {
      throw new Error("Stack Auth user cannot grant team permissions");
    }
    await user.grantPermission(team, TEAM_ADMIN_PERMISSION);
  } catch (error) {
    await team.delete?.().catch(() => {
      console.error("legacy checkout team rollback failed", { teamId: team.id });
    });
    throw error;
  }
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
