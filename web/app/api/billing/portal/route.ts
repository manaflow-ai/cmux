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
import { resolveProPlanStatus } from "../../../../services/billing/pro";
import {
  isStripeBillingConfigured,
  resolvePersonalPlanSwitchPortalConfiguration,
  stripe,
} from "../../../../services/billing/stripe";
import { MAX_PLAN_ID, PRO_PLAN_ID, stripeBillingStatusForUser } from "../../../../services/billing/pro";
import { resolveBillingTeam } from "../../../../services/billing/teamResolution";


const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
type GetStackServerApp = typeof StackLib.getStackServerApp;

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
    const team = requestedScope === "team" ? await resolveBillingTeam(user) : null;
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

    const returnUrl = new URL("/dashboard/billing", requestOrigin(request)).toString();
    // `flow=switch_plan&plan=max|pro` opens Stripe's plan-change flow on the
    // caller's active personal subscription, with the dedicated configuration
    // that lists Pro and Max. Any state that cannot switch (no active personal
    // subscription, team scope, or a flow the catalog has not provisioned)
    // falls back to the plain portal so the person can still manage billing.
    const planSwitch = !team ? await personalPlanSwitchFlow(request, user.id) : null;
    const session = await stripe().billingPortal.sessions.create({
      customer: customerId,
      return_url: returnUrl,
      ...(planSwitch ?? {}),
    });
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

async function stripeCustomerIdForStackTeam(stackTeamId: string): Promise<string | null> {
  const rows = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackTeamId, stackTeamId))
    .limit(1);
  return rows[0]?.id ?? null;
}

type PortalPlanSwitchParams = {
  readonly configuration: string;
  readonly flow_data: {
    readonly type: "subscription_update";
    readonly subscription_update: { readonly subscription: string };
  };
};

async function personalPlanSwitchFlow(
  request: NextRequest,
  stackUserId: string,
): Promise<PortalPlanSwitchParams | null> {
  const params = request.nextUrl.searchParams;
  if (params.get("flow") !== "switch_plan") return null;
  const target = params.get("plan")?.trim().toLowerCase();
  if (target !== MAX_PLAN_ID && target !== PRO_PLAN_ID) return null;
  const status = await stripeBillingStatusForUser(stackUserId);
  if (
    !status.hasActiveSubscription ||
    !status.subscriptionId ||
    status.activePlanId === null ||
    status.activePlanId === target
  ) {
    return null;
  }
  try {
    const configuration = await resolvePersonalPlanSwitchPortalConfiguration();
    return {
      configuration,
      flow_data: {
        type: "subscription_update",
        subscription_update: { subscription: status.subscriptionId },
      },
    };
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/portal",
      stackUserId,
      planSwitchTarget: target,
    });
    return null;
  }
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
