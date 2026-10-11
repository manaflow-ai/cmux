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
import {
  APP_STORE_BUNDLE_ID,
  appleBundleIds,
  appleEnvironmentGrantsEntitlement,
  appleProductId,
  isAcceptedAppleBundleId,
  isSignedAppleEnvironment,
  type SignedAppleEnvironment,
} from "./config";
import { databaseAppleIapStore, type AppleIapStore } from "./store";

export type AppleIneligibleReason = "stripe_subscription_active" | "team_billing" | "purchases_unavailable";

/** The app build asking: its bundle ID and, when the app sent it, its StoreKit environment. */
export type AppleAccountTokenApp = {
  readonly bundleId: string | null;
  readonly storeKitEnvironment: SignedAppleEnvironment | null;
};

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
  /** Deployment config for the Sandbox entitlement policy; defaults to the process environment. */
  readonly env?: Record<string, string | undefined>;
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

/** Account reasons first: they tell the user where billing lives. */
function ineligibleReason(input: {
  readonly stripeActive: boolean;
  readonly teamBilled: boolean;
  readonly purchasesGrant: boolean;
}): AppleIneligibleReason | null {
  if (input.stripeActive) return "stripe_subscription_active";
  if (input.teamBilled) return "team_billing";
  return input.purchasesGrant ? null : "purchases_unavailable";
}

/** Unknown bundle IDs get no products; a missing header means the App Store app. */
export function requestedAppleBundleId(header: string | null): string | null {
  const value = header?.trim();
  if (!value) return appleBundleIds()[0] ?? null;
  return isAcceptedAppleBundleId(value) ? value : null;
}

/** `x-cmux-storekit-environment`: `Sandbox` or `Production`, else unknown. */
export function requestedStoreKitEnvironment(header: string | null): SignedAppleEnvironment | null {
  const value = header?.trim();
  return isSignedAppleEnvironment(value) ? value : null;
}

/**
 * Whether a purchase from this build would grant a plan here. TestFlight
 * builds always buy in the Sandbox and App Store builds in Production, so an
 * app that did not say which applies is assumed Sandbox unless it is the App
 * Store bundle. Selling a purchase that grants nothing would show a completed
 * purchase with no plan.
 */
function purchasesGrant(app: AppleAccountTokenApp, env: Record<string, string | undefined>): boolean {
  if (!app.bundleId) return false;
  const environment = app.storeKitEnvironment ?? (app.bundleId === APP_STORE_BUNDLE_ID ? "Production" : "Sandbox");
  return appleEnvironmentGrantsEntitlement({ environment, bundleId: app.bundleId }, env);
}

/** `POST /api/billing/apple/account-token`. */
export async function appleAccountTokenResponse(
  user: AppleAccountUser,
  app: AppleAccountTokenApp,
  deps: AppleAccountTokenDependencies = defaultDependencies(),
): Promise<AppleAccountTokenResponse> {
  const [appAccountToken, stripeActive, teamBilled, status, goEnabled] = await Promise.all([
    deps.store.accountTokenForUser(user.id),
    deps.hasActiveStripeSubscription(user.id),
    deps.billedThroughTeam(user),
    deps.planStatus(user),
    deps.goPlanEnabled(user.id),
  ]);
  const reason = ineligibleReason({
    stripeActive,
    teamBilled,
    purchasesGrant: purchasesGrant(app, deps.env ?? process.env),
  });
  const plans: PersonalPlanId[] = goEnabled ? ["go", "pro", "max"] : ["pro", "max"];
  const { bundleId } = app;
  return {
    appAccountToken,
    eligible: reason === null,
    reason,
    currentPlan: {
      planId: status.planId,
      source: status.billingSource,
      ...(status.manageUrl ? { manageUrl: status.manageUrl } : {}),
    },
    products: bundleId && reason !== "purchases_unavailable"
      ? plans.map((planId) => ({ productId: appleProductId(bundleId, planId), planId }))
      : [],
  };
}
