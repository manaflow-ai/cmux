import { NextRequest, NextResponse } from "next/server";

import { localizedVaultPath, vaultSignInHref } from "../../../lib/vault-auth";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { locales, routing } from "../../../../i18n/routing";
import { isStripeBillingConfigured } from "../../../../services/billing/stripe";
import {
  resolveBillingTeam,
  type BillingTeamUserLike,
} from "../../../../services/billing/teamResolution";
import { claimPendingProBilling } from "../../../../services/billing/purchase";
import {
  applySubscriptionAction,
  type SubscriptionAction,
} from "../../../../services/billing/subscriptionManagement";
import { captureBillingError } from "../../../../services/errors";
import { browserMutationOriginAllowed } from "../../../../services/vms/routeHelpers";


const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
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

    if (
      user.isAnonymous !== true &&
      user.isRestricted !== true &&
      user.primaryEmailVerified === true &&
      user.primaryEmail
    ) {
      try {
        await claimPendingProBilling(user);
      } catch {
        // Keep the existing action path available; the next read retries.
      }
    }

    const applied = await applySubscriptionAction({
      scope,
      ownerId: scope === "team" ? await verifiedBillingTeamId(user, formData) : user.id,
      action,
    });
    if (!applied) {
      return billingRedirect(request, "nosub");
    }

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
  const team = await resolveBillingTeam(user as BillingTeamUserLike);
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
