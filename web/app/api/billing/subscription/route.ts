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
  TEAM_PLAN_ID,
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
type BillingScope = "user" | "team";

export async function POST(request: NextRequest) {
  let stackUserId: string | undefined;
  let action: SubscriptionAction | null = null;
  let scope: BillingScope = "user";

  if (!browserMutationOriginAllowed(request)) {
    return billingRedirect(request, "error");
  }

  try {
    const formData = await request.formData();
    action = subscriptionAction(formData);
    if (!action) {
      return billingRedirect(request, "error");
    }
    scope = billingScope(formData);

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

    const subscription = scope === "team"
      ? await activeStripeSubscriptionForStackTeam(await verifiedBillingTeamId(user, formData))
      : await activeStripeSubscriptionForStackUser(user.id);
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
      scope,
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

function billingScope(formData: FormData): BillingScope {
  return formData.get("scope") === "team" ? "team" : "user";
}

async function verifiedBillingTeamId(user: unknown, formData: FormData): Promise<string> {
  const team = await billingTeamForUser(user as BillingTeamUserLike);
  const clientTeamId = formData.get("teamId");
  if (
    typeof clientTeamId === "string" &&
    clientTeamId.trim() &&
    clientTeamId.trim() !== team?.id
  ) {
    throw new Error("Billing team does not belong to the current user");
  }
  if (!team?.id) {
    throw new Error("No billing team is available for the current user");
  }
  return team.id;
}

async function activeStripeSubscriptionForStackUser(stackUserId: string) {
  const rows = await cloudDb()
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

async function activeStripeSubscriptionForStackTeam(stackTeamId: string) {
  const rows = await cloudDb()
    .select({ id: stripeSubscriptions.id })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackTeamId, stackTeamId),
        eq(stripeSubscriptions.scope, "team"),
        eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
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

type BillingTeamLike = { readonly id?: string };
type BillingTeamUserLike = {
  readonly selectedTeam?: unknown;
  readonly listTeams?: () => Promise<readonly unknown[]>;
};

async function billingTeamForUser(user: BillingTeamUserLike): Promise<BillingTeamLike | null> {
  const selected = teamFromUnknown(user.selectedTeam);
  if (selected) return selected;
  const teams = typeof user.listTeams === "function"
    ? (await user.listTeams()).map(teamFromUnknown).filter((team): team is BillingTeamLike => !!team)
    : [];
  return teams.length === 1 ? teams[0] : null;
}

function teamFromUnknown(value: unknown): BillingTeamLike | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { id?: unknown }).id;
  return typeof id === "string" && id ? { id } : null;
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
