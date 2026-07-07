import { and, desc, eq, inArray, sql } from "drizzle-orm";
import { NextRequest, NextResponse } from "next/server";

import { cloudDb } from "../../../../db/client";
import { stripeSubscriptions } from "../../../../db/schema";
import { localizedVaultPath, vaultSignInHref } from "../../../lib/vault-auth";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { locales, routing } from "../../../../i18n/routing";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
} from "../../../../services/billing/pro";
import {
  isStripeBillingConfigured,
  stripe,
} from "../../../../services/billing/stripe";
import { captureBillingError } from "../../../../services/errors";
import { browserMutationOriginAllowed } from "../../../../services/vms/routeHelpers";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
type SubscriptionAction = "cancel" | "resume";

export async function POST(request: NextRequest) {
  let stackUserId: string | undefined;
  let action: SubscriptionAction | null = null;

  if (!browserMutationOriginAllowed(request)) {
    return billingRedirect(request, "error");
  }

  try {
    action = subscriptionAction(await request.formData());
    if (!action) {
      return billingRedirect(request, "error");
    }

    if (!isStackConfigured()) {
      throw new Error("Billing subscription management is not configured");
    }

    const user = await currentStackUser();
    if (!user) {
      return NextResponse.redirect(
        new URL(vaultSignInHref(localizedVaultPath(requestLocale(request), "/dashboard/billing")), request.url),
        303,
      );
    }
    stackUserId = user.id;

    if (!isStripeBillingConfigured()) {
      throw new Error("Billing subscription management is not configured");
    }

    const subscription = await activeStripeSubscriptionForStackUser(user.id);
    if (!subscription) {
      return billingRedirect(request, "nosub");
    }

    const updated = await stripe().subscriptions.update(subscription.id, {
      cancel_at_period_end: action === "cancel",
    });
    await updateSubscriptionSnapshot(subscription.id, updated);

    return billingRedirect(request, action === "cancel" ? "cancelled" : "resumed");
  } catch (error) {
    captureBillingError(error, {
      route: "/api/billing/subscription",
      stackUserId,
      action,
    });
    return billingRedirect(request, "error");
  }
}

async function currentStackUser() {
  const stackServerApp = getStackServerApp();
  return (
    (await stackServerApp.getUser({ or: "return-null" })) ??
    (await stackServerApp.getUser({ or: ANONYMOUS_IF_EXISTS }))
  );
}

function subscriptionAction(formData: FormData): SubscriptionAction | null {
  const action = formData.get("action");
  return action === "cancel" || action === "resume" ? action : null;
}

async function activeStripeSubscriptionForStackUser(stackUserId: string) {
  const rows = await cloudDb()
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

async function updateSubscriptionSnapshot(
  subscriptionId: string,
  subscription: { cancel_at_period_end?: boolean },
) {
  await cloudDb()
    .update(stripeSubscriptions)
    .set({
      cancelAtPeriodEnd: Boolean(subscription.cancel_at_period_end),
      raw: JSON.parse(JSON.stringify(subscription)) as Record<string, unknown>,
      updatedAt: sql`now()`,
    })
    .where(eq(stripeSubscriptions.id, subscriptionId));
}

function billingRedirect(
  request: NextRequest,
  billing: "cancelled" | "resumed" | "nosub" | "error",
) {
  const url = new URL(localizedBillingPath(request), request.url);
  url.searchParams.set("billing", billing);
  return NextResponse.redirect(url, 303);
}

function localizedBillingPath(request: NextRequest): string {
  const locale = requestLocale(request);
  return locale === routing.defaultLocale
    ? "/dashboard/billing"
    : `/${locale}/dashboard/billing`;
}

function requestLocale(request: NextRequest): string {
  const referer = request.headers.get("referer");
  if (referer) {
    try {
      const firstSegment = new URL(referer).pathname.split("/").filter(Boolean)[0];
      if (locales.includes(firstSegment as (typeof locales)[number])) {
        return firstSegment;
      }
    } catch {
      // Ignore malformed referers and fall back to the default locale.
    }
  }
  return routing.defaultLocale;
}
