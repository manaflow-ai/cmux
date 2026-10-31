import { and, eq, isNull } from "drizzle-orm";
import { NextRequest, NextResponse } from "next/server";
import type * as StackLib from "../../../lib/stack";
import { requestOrigin, requestWithOrigin } from "../../../lib/request-origin";

import { cloudDb } from "../../../../db/client";
import { stripeCustomers } from "../../../../db/schema";
import {
  appStorePricingUnavailableURL,
  isAppStoreDistributionMode,
} from "../../../lib/billing";
import { captureBillingError } from "../../../../services/errors";
import { resolveProPlanStatus, stripeBillingStatusForUser } from "../../../../services/billing/pro";
import {
  isStripeBillingConfigured,
  stripe,
} from "../../../../services/billing/stripe";
import {
  personalPortalSession,
  personalSwitchLinkRedirect,
} from "../../../../services/billing/personalPortal";
import { checkoutAttributionFromRequest } from "../../../../services/analytics/checkoutAttribution";
import { resolveBillingTeam } from "../../../../services/billing/teamResolution";
import { isWebPlusPlanEnabled as isGoPlanEnabled } from "../../../../services/billing/goPlanFlag";
import {
  explicitTeamId,
  resolveTeamBillingAccess,
  type TeamBillingAccessError,
  type TeamBillingAccessUser,
} from "../../../../services/billing/teamBillingAccess";
import {
  stripeCustomerIdForStackTeam,
  teamBillingReturnURL,
  teamPortalSession,
} from "../../../../services/billing/teamPortal";
import {
  PAYMENT_METHOD_RETURN_FLOW,
  PAYMENT_METHOD_UPDATE_FLOW,
  isValidPaymentReturnToken,
  paymentMethodUpdatePortalSession,
  paymentReturnToken,
  recoverFailedSubscriptionPayments,
  type PaymentRecoveryOutcome,
} from "../../../../services/billing/paymentRecovery";


const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
type GetStackServerApp = typeof StackLib.getStackServerApp;

// oxlint-disable-next-line complexity -- Portal routing keeps auth, App Store policy, team scope, recovery, and plan-switch decisions in one billing boundary.
export async function GET(request: NextRequest) {
  if (
    isAppStoreDistributionMode({
      cmux_distribution: request.nextUrl.searchParams.get("cmux_distribution"),
      cmux_ios_app_store: request.nextUrl.searchParams.get("cmux_ios_app_store"),
    })
  ) {
    return NextResponse.redirect(
      appStorePricingUnavailableURL(requestWithOrigin(request).nextUrl),
      302,
    );
  }

  // Keep Stack deferred until after the App Store distribution gate. lib/stack
  // eagerly initializes stackServerApp, and this route must not do auth work for
  // App Store billing-management requests.
  const { getStackServerApp, isStackConfigured } = await import("../../../lib/stack");
  if (!isStackConfigured() || !isStripeBillingConfigured()) {
    return pricingRedirect(request, "unavailable");
  }

  let stackUserId: string | undefined;
  try {
    const user = await currentStackUser(getStackServerApp);
    if (!user) {
      return NextResponse.redirect(new URL("/pricing", requestOrigin(request)), 302);
    }
    stackUserId = user.id;

    const requestedScope = billingPortalScope(request.nextUrl.searchParams.get("scope"));
    const requestedTeamId = requestedScope === "team"
      ? explicitTeamId(request.nextUrl.searchParams.get("teamId"))
      : null;
    const flow = paymentMethodFlow(request.nextUrl.searchParams.get("flow"));
    if (requestedTeamId) return await explicitTeamPortal(request, user, requestedTeamId, flow);
    // Legacy `?scope=team` without a team id: the implicit billing team, which
    // still needs the caller to be its admin.
    const team = requestedScope === "team" ? await resolveBillingTeam(user) : null;
    if (team?.id) return await explicitTeamPortal(request, user, team.id, flow);
    if (flow) {
      const personalCustomerId = await stripeCustomerIdForStackUser(user.id);
      if (!personalCustomerId) return pricingRedirect(request, "unavailable");
      return await paymentMethodFlowResponse(request, { customerId: personalCustomerId, teamId: null, flow });
    }
    const target = request.nextUrl.searchParams.get("plan");
    const wantsSwitch = !team && request.nextUrl.searchParams.get("flow") === "switch_plan" && (target === "go" || target === "max" || target === "pro");
    if (wantsSwitch && target === "go" && !(await isGoPlanEnabled(user.id))) {
      return NextResponse.redirect(new URL("/pricing?billing=plan_unavailable", requestOrigin(request)), 302);
    }
    // A switch the hosted portal cannot do goes to checkout or the dashboard
    // dialog, including for an account with no Stripe customer yet.
    const switchStatus = wantsSwitch ? await stripeBillingStatusForUser(user.id) : null;
    const switchRedirect = switchStatus && wantsSwitch
      ? personalSwitchLinkRedirect({
          status: switchStatus, origin: requestOrigin(request), target, searchParams: request.nextUrl.searchParams,
        })
      : null;
    if (switchRedirect) return NextResponse.redirect(switchRedirect, 302);
    const customerId = team?.id
      ? await stripeCustomerIdForStackTeam(team.id)
      : await stripeCustomerIdForStackUser(user.id);
    if (!customerId) {
      const status = await resolveProPlanStatus(user);
      if (!team && status.billingManagement === "stripe") {
        captureBillingError(
          new Error("Stripe-managed billing user is missing a Stripe customer row"),
          {
            route: "/api/billing/portal",
            stackUserId: user.id,
            billingManagement: status.billingManagement,
          },
        );
      }
      return pricingRedirect(request, "unavailable");
    }

    const returnUrl = team?.id
      ? teamBillingReturnURL(requestOrigin(request), team.id)
      : new URL("/dashboard/billing", requestOrigin(request)).toString();
    const session = wantsSwitch
      ? await personalPortalSession({
          userId: user.id, origin: requestOrigin(request), target, status: switchStatus ?? undefined,
          attribution: checkoutAttributionFromRequest({ searchParams: request.nextUrl.searchParams, referer: request.headers.get("referer") }),
        })
      : await stripe().billingPortal.sessions.create({ customer: customerId, return_url: returnUrl });
    if (!session.url) {
      throw new Error("Stripe Billing Portal Session did not include a URL");
    }
    return NextResponse.redirect(session.url, 302);
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/portal",
      stackUserId,
      stripePortalConfigurationMissing: isStripePortalConfigurationError(error),
    });
    return pricingRedirect(request, "error");
  }
}

/**
 * `?scope=team&teamId=`: the named team's portal, for its admins only.
 * Refusals return to that team's billing view with a banner code.
 */
async function explicitTeamPortal(
  request: NextRequest,
  user: TeamBillingAccessUser,
  teamId: string,
  flow: PaymentMethodFlow | null,
): Promise<NextResponse> {
  const access = await resolveTeamBillingAccess(user, teamId, { requireAdmin: true });
  if (!access.ok) return teamBillingRedirect(request, teamId, access.error);
  if (flow) {
    const customerId = await stripeCustomerIdForStackTeam(teamId);
    if (!customerId) return teamBillingRedirect(request, teamId, "nosub");
    return await paymentMethodFlowResponse(request, { customerId, teamId, flow });
  }
  const session = await teamPortalSession({ teamId, origin: requestOrigin(request) });
  if (!session) return teamBillingRedirect(request, teamId, "nosub");
  return NextResponse.redirect(session.url, 302);
}

type PaymentMethodFlow = typeof PAYMENT_METHOD_UPDATE_FLOW | typeof PAYMENT_METHOD_RETURN_FLOW;

function paymentMethodFlow(raw: string | null): PaymentMethodFlow | null {
  return raw === PAYMENT_METHOD_UPDATE_FLOW || raw === PAYMENT_METHOD_RETURN_FLOW ? raw : null;
}

/** The dashboard banner for each recovery outcome; none when nothing changed. */
const PAYMENT_RECOVERY_BANNER: Readonly<Record<Exclude<PaymentRecoveryOutcome, "action_required">, string | null>> = {
  recovered: "payment_updated",
  payment_failed: "payment_failed",
  no_payment_method: null,
  nothing_due: null,
};

/**
 * `flow=payment_method_update` opens the portal on its card form. Saving a
 * card returns to `flow=payment_method_return` with a signed token, which
 * settles any failed subscription with the saved card and shows the result on
 * the billing dashboard; leaving the portal returns to the dashboard and
 * charges nothing.
 */
async function paymentMethodFlowResponse(
  request: NextRequest,
  input: { readonly customerId: string; readonly teamId: string | null; readonly flow: PaymentMethodFlow },
): Promise<NextResponse> {
  const origin = requestOrigin(request);
  const dashboard = new URL("/dashboard/billing", origin);
  if (input.teamId) dashboard.searchParams.set("team", input.teamId);
  if (input.flow === PAYMENT_METHOD_UPDATE_FLOW) {
    const token = paymentReturnToken(input.customerId);
    if (!token) throw new Error("Stripe billing is not configured");
    const completedURL = new URL("/api/billing/portal", origin);
    completedURL.searchParams.set("flow", PAYMENT_METHOD_RETURN_FLOW);
    if (input.teamId) {
      completedURL.searchParams.set("scope", "team");
      completedURL.searchParams.set("teamId", input.teamId);
    }
    completedURL.searchParams.set("token", token);
    const session = await paymentMethodUpdatePortalSession({
      customerId: input.customerId, completedURL: completedURL.toString(), cancelURL: dashboard.toString(),
    });
    return NextResponse.redirect(session.url, 302);
  }
  // Only the completion link of a portal session made for this customer may
  // charge; any other request to the return flow just shows the dashboard.
  if (!isValidPaymentReturnToken(request.nextUrl.searchParams.get("token"), input.customerId)) {
    return NextResponse.redirect(dashboard, 302);
  }
  let banner: string | null;
  try {
    const result = await recoverFailedSubscriptionPayments(input.customerId);
    if (result.outcome === "action_required") return NextResponse.redirect(result.hostedInvoiceURL, 302);
    banner = PAYMENT_RECOVERY_BANNER[result.outcome];
  } catch (error) {
    captureBillingError(error, { route: "/api/billing/portal", operation: "payment_recovery", stackTeamId: input.teamId ?? undefined });
    banner = "error";
  }
  if (banner) dashboard.searchParams.set("billing", banner);
  return NextResponse.redirect(dashboard, 302);
}

function teamBillingRedirect(
  request: NextRequest,
  teamId: string,
  billing: TeamBillingAccessError | "nosub",
): NextResponse {
  const url = new URL("/dashboard/billing", requestOrigin(request));
  if (billing !== "personal_team_not_upgradable_to_team") url.searchParams.set("team", teamId);
  url.searchParams.set("billing", billing);
  return NextResponse.redirect(url, 302);
}

async function currentStackUser(getStackServerApp: GetStackServerApp) {
  const stackServerApp = getStackServerApp();
  return (
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: ANONYMOUS_IF_EXISTS }))
  );
}

async function stripeCustomerIdForStackUser(stackUserId: string): Promise<string | null> {
  const rows = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(
      and(
        eq(stripeCustomers.stackUserId, stackUserId),
        isNull(stripeCustomers.stackTeamId),
      ),
    )
    .limit(1);
  return rows[0]?.id ?? null;
}

function billingPortalScope(raw: string | null): "user" | "team" {
  return raw === "team" ? "team" : "user";
}

function pricingRedirect(request: NextRequest, billing: "unavailable" | "error") {
  return NextResponse.redirect(new URL(`/pricing?billing=${billing}`, requestOrigin(request)), 302);
}

function isStripePortalConfigurationError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /billing portal/i.test(message) && /configur/i.test(message);
}
