import { isGoPlanEnabled } from "../goPlanFlag";
import {
  resolveProPlanStatus,
  stripeBillingStatusForUser,
  type PersonalBillingSource,
  type PersonalPlanId,
  type ProReconcileUser,
} from "../pro";
import { teamPlanStatusForTeam } from "../teamPlanStatus";
import { resolveBillingTeam, type BillingTeamUserLike } from "../teamResolution";
import { appleBundleIds, appleProductId, isAcceptedAppleBundleId } from "./config";
import { databaseAppleIapStore, type AppleIapStore } from "./store";

export type AppleIneligibleReason = "stripe_subscription_active" | "team_billing";

export type AppleAccountTokenResponse = {
  readonly appAccountToken: string;
  readonly eligible: boolean;
  readonly reason: AppleIneligibleReason | null;
  readonly currentPlan: {
    readonly planId: string;
    readonly source: PersonalBillingSource;
    readonly manageUrl?: string;
  };
  readonly products: readonly { readonly productId: string; readonly planId: PersonalPlanId }[];
};

export type AppleAccountUser = ProReconcileUser & BillingTeamUserLike & { readonly id: string };

export type AppleAccountTokenDependencies = {
  readonly store: Pick<AppleIapStore, "accountTokenForUser">;
  readonly goPlanEnabled: (userId: string) => Promise<boolean>;
  readonly hasActiveStripeSubscription: (userId: string) => Promise<boolean>;
  readonly billedThroughTeam: (user: AppleAccountUser) => Promise<boolean>;
  readonly planStatus: typeof resolveProPlanStatus;
};

const defaultDependencies = (): AppleAccountTokenDependencies => ({
  store: databaseAppleIapStore(),
  goPlanEnabled: (userId) => isGoPlanEnabled(userId),
  hasActiveStripeSubscription: async (userId) => {
    const status = await stripeBillingStatusForUser(userId);
    return status.hasActiveSubscription || status.hasRecurringSubscription === true;
  },
  billedThroughTeam: async (user) => {
    const team = await resolveBillingTeam(user);
    return team ? (await teamPlanStatusForTeam(team)).planId === "team" : false;
  },
  planStatus: resolveProPlanStatus,
});

/** Unknown bundle IDs get no products; a missing header means the App Store app. */
export function requestedAppleBundleId(header: string | null): string | null {
  const value = header?.trim();
  if (!value) return appleBundleIds()[0] ?? null;
  return isAcceptedAppleBundleId(value) ? value : null;
}

/** `POST /api/billing/apple/account-token`. */
export async function appleAccountTokenResponse(
  user: AppleAccountUser,
  bundleId: string | null,
  deps: AppleAccountTokenDependencies = defaultDependencies(),
): Promise<AppleAccountTokenResponse> {
  const [appAccountToken, stripeActive, teamBilled, status, goEnabled] = await Promise.all([
    deps.store.accountTokenForUser(user.id),
    deps.hasActiveStripeSubscription(user.id),
    deps.billedThroughTeam(user),
    deps.planStatus(user),
    deps.goPlanEnabled(user.id),
  ]);
  const reason: AppleIneligibleReason | null = stripeActive
    ? "stripe_subscription_active"
    : teamBilled ? "team_billing" : null;
  const plans: PersonalPlanId[] = goEnabled ? ["go", "pro", "max"] : ["pro", "max"];
  return {
    appAccountToken,
    eligible: reason === null,
    reason,
    currentPlan: {
      planId: status.planId,
      source: status.billingSource,
      ...(status.manageUrl ? { manageUrl: status.manageUrl } : {}),
    },
    products: bundleId
      ? plans.map((planId) => ({ productId: appleProductId(bundleId, planId), planId }))
      : [],
  };
}
