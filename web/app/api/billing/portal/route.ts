import { eq } from "drizzle-orm";
import { NextRequest, NextResponse } from "next/server";
import type * as StackLib from "../../../lib/stack";

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
  stripe,
} from "../../../../services/billing/stripe";
import { resolveBillingTeam } from "../../../../services/billing/teamResolution";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
type GetStackServerApp = typeof StackLib.getStackServerApp;

export async function GET(request: NextRequest) {
  if (
    isAppStoreDistributionMode({
      cmux_distribution: request.nextUrl.searchParams.get("cmux_distribution"),
      cmux_ios_app_store: request.nextUrl.searchParams.get("cmux_ios_app_store"),
    })
  ) {
    return NextResponse.redirect(appStorePricingUnavailableURL(request.nextUrl), 302);
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
      return NextResponse.redirect(new URL("/pricing", request.url), 302);
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

    const session = await stripe().billingPortal.sessions.create({
      customer: customerId,
      return_url: new URL(
        team ? "/dashboard/billing" : "/pricing",
        request.nextUrl.origin,
      ).toString(),
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
    .where(eq(stripeCustomers.stackUserId, stackUserId))
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

function billingPortalScope(raw: string | null): "user" | "team" {
  return raw === "team" ? "team" : "user";
}

function pricingRedirect(request: NextRequest, billing: "unavailable" | "error") {
  return NextResponse.redirect(new URL(`/pricing?billing=${billing}`, request.url), 302);
}

function isStripePortalConfigurationError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /billing portal/i.test(message) && /configur/i.test(message);
}
