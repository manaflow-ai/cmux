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
import {
  explicitTeamId,
  resolveTeamBillingAccess,
  type TeamBillingAccessError,
  type TeamBillingAccessUser,
} from "../../../../services/billing/teamBillingAccess";


const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
type BillingScope = "user" | "team";
type BillingRedirectCode = "cancelled" | "resumed" | "nosub" | "error" | TeamBillingAccessError;

class TeamBillingRefusal extends Error {
  override readonly name = "TeamBillingRefusal";
  constructor(readonly code: TeamBillingAccessError, readonly teamId: string) {
    super(code);
  }
}

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

    const ownerId = scope === "team" ? await verifiedBillingTeamId(user, formData) : user.id;
    const teamId = scope === "team" ? ownerId : null;
    const applied = await applySubscriptionAction({ scope, ownerId, action });
    if (!applied) {
      return billingRedirect(request, "nosub", teamId);
    }

    return billingRedirect(request, action === "cancel" ? "cancelled" : "resumed", teamId);
  } catch (error) {
    if (error instanceof TeamBillingRefusal) {
      return billingRedirect(request, error.code, error.code === "personal_team_not_upgradable_to_team" ? null : error.teamId);
    }
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

/**
 * With a `teamId` field the named team is the subject and the caller must be
 * its admin. Without one (older app forms) the implicit billing team applies.
 */
async function verifiedBillingTeamId(user: unknown, formData: FormData): Promise<string> {
  const requestedTeamId = explicitTeamId(formData.get("teamId"));
  if (requestedTeamId) {
    const access = await resolveTeamBillingAccess(user as TeamBillingAccessUser, requestedTeamId, { requireAdmin: true });
    if (!access.ok) throw new TeamBillingRefusal(access.error, requestedTeamId);
    return access.team.id;
  }
  const team = await resolveBillingTeam(user as BillingTeamUserLike);
  if (!team?.id) {
    throw new Error("No billing team is available for the current user");
  }
  return team.id;
}

function billingRedirect(
  request: NextRequest,
  billing: BillingRedirectCode,
  teamId: string | null = null,
) {
  const url = new URL(localizedBillingPath(request), request.url);
  if (teamId) url.searchParams.set("team", teamId);
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
