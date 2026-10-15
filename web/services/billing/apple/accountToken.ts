import { isAdminUser } from "../../admin/access";
import { isGoPlanEnabled } from "../goPlanFlag";
import { resolveIosPaywall, type IosPaywallRequest } from "../paywall/iosPaywall";
import type { IosPaywallConfig, IosPaywallLayout } from "../paywall/validator";
import { planFacts, type PlanFacts } from "../paywall/planFacts";
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
  APPLE_PLAN_BILLING_PERIODS,
  appleProductId,
  type AppleBillingPeriod,
  isAcceptedAppleBundleId,
  isSignedAppleEnvironment,
  type SignedAppleEnvironment,
} from "./config";
import { databaseAppleIapStore, type AppleIapStore } from "./store";
import { activeAppleEntitlementForUser } from "./entitlement";
import { trialOffer, type TrialOffer } from "./trial";
import { isTrialConfigured, TRIAL_BUNDLE_ID, TRIAL_LIMITS, TRIAL_PAYWALL_VARIANT } from "./trialConfig";
import { databaseTrialStore } from "./trialStore";

export type AppleIneligibleReason = "stripe_subscription_active" | "team_billing" | "purchases_unavailable";

/** The app build asking: its bundle ID and, when the app sent it, its StoreKit environment. */
export type AppleAccountTokenApp = {
  readonly bundleId: string | null;
  readonly storeKitEnvironment: SignedAppleEnvironment | null;
  /**
   * Periods the app can show (`x-cmux-billing-periods`). Older apps list
   * every product in one plan list, so they get monthly products only.
   */
  readonly billingPeriods?: readonly AppleBillingPeriod[];
  /**
   * The raw `x-cmux-bundle-id` header. Unlike `bundleId` it has no default,
   * so only an app that says it is the App Store app enters paywall
   * experiments as the production channel.
   */
  readonly bundleIdHeader?: string | null;
  /** Paywall layouts this app can draw (`x-cmux-paywall-layouts`). */
  readonly paywallLayouts?: readonly IosPaywallLayout[];
};

export type AppleAccountTokenResponse = {
  readonly appAccountToken: string;
  readonly eligible: boolean;
  readonly reason: AppleIneligibleReason | null;
  readonly currentPlan: {
    readonly planId: string;
    readonly source: PersonalBillingSource;
    readonly manageUrl?: string;
    /** Present while the account is in the iOS Pro free trial (limited trial entitlement). */
    readonly trial?: { readonly endsAt: string; readonly limits: typeof TRIAL_LIMITS };
  };
  readonly products: readonly {
    readonly productId: string;
    readonly planId: PersonalPlanId;
    readonly billingPeriod: AppleBillingPeriod;
  }[];
  /** The server-configured paywall (services/billing/paywall); control outside the experiment. */
  readonly paywall?: IosPaywallConfig;
  /** Cloud VM limits per offered plan, from facts.ts (Go only when Go is offered). */
  readonly planFacts?: PlanFacts;
  /** Present and true for cmux staff: the app shows its Paywall Lab. */
  readonly staff?: true;
  /**
   * The account may get the 7-day Pro trial if its device passes
   * `POST /api/billing/apple/trial/verify`. Absent: no trial.
   */
  readonly trial?: TrialOffer;
};

export type AppleAccountUser = ProReconcileUser & BillingTeamUserLike & {
  readonly id: string;
  /** The signed-in account's primary email; production Sandbox purchases need it verified and on the allowlist. */
  readonly primaryEmail?: string | null;
  readonly primaryEmailVerified?: boolean;
};

export type AppleAccountTokenDependencies = {
  readonly store: Pick<AppleIapStore, "accountTokenForUser">;
  readonly goPlanEnabled: (userId: string) => Promise<boolean>;
  readonly hasActiveStripeSubscription: (userId: string) => Promise<boolean>;
  readonly billedThroughTeam: (user: AppleAccountUser) => Promise<boolean>;
  readonly planStatus: typeof resolveProPlanStatus;
  /** The paywall for this user; absent in callers that do not serve one. */
  readonly paywall?: (user: AppleAccountUser, request: IosPaywallRequest) => Promise<IosPaywallConfig>;
  /** Trial state; absent in callers that never offer the trial. */
  readonly trial?: {
    readonly accountTrialed: (userId: string) => Promise<boolean>;
    /** The end of the account's current free-trial period, or null. */
    readonly activeTrialEndsAt: (userId: string) => Promise<Date | null>;
  };
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
  paywall: (user, request) => resolveIosPaywall(user, request),
  trial: {
    accountTrialed: async (userId) => (await databaseTrialStore().claim(userId))?.status === "started",
    activeTrialEndsAt: async (userId) => {
      const row = await activeAppleEntitlementForUser(userId);
      return row?.freeTrial ? row.expiresAt : null;
    },
  },
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

/** `x-cmux-billing-periods: monthly,yearly`: the periods this app can show; monthly always. */
export function requestedBillingPeriods(header: string | null): readonly AppleBillingPeriod[] {
  const values = new Set((header ?? "").split(",").map((value) => value.trim().toLowerCase()));
  return values.has("yearly") ? ["monthly", "yearly"] : ["monthly"];
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
 * purchase with no plan. In production a Sandbox purchase grants only for an
 * allowlisted account email, so every other TestFlight tester sees no
 * products instead of a purchase that grants nothing.
 */
function purchasesGrant(
  app: AppleAccountTokenApp,
  accountEmail: string | null | undefined,
  env: Record<string, string | undefined>,
): boolean {
  if (!app.bundleId) return false;
  const environment = app.storeKitEnvironment ?? (app.bundleId === APP_STORE_BUNDLE_ID ? "Production" : "Sandbox");
  return appleEnvironmentGrantsEntitlement({ environment, bundleId: app.bundleId, accountEmail }, env);
}

/**
 * Whether the account could get the trial in this app (App Store app,
 * purchasable, free plan, trial configured, never trialed), before its
 * paywall arm is known. The paywall serves the trial arm only then, and the
 * trial is offered only to an eligible account in the trial arm.
 */
async function accountTrialEligible(
  userId: string,
  input: {
    readonly deps: AppleAccountTokenDependencies;
    readonly bundleIdHeader: string | null;
    readonly purchasable: boolean;
    readonly status: { readonly planId: string };
  },
): Promise<boolean> {
  const trial = input.deps.trial;
  if (!trial) return false;
  const candidate = input.bundleIdHeader?.trim() === TRIAL_BUNDLE_ID
    && input.purchasable
    && input.status.planId === "free"
    && isTrialConfigured(input.deps.env ?? process.env);
  // Trial lookups fail closed (no offer) and never fail the account-token
  // response that sells the regular plans.
  return candidate && await trial.accountTrialed(userId).then((trialed) => !trialed, () => false);
}

/** The end of the trial the account is in now (a free-trial period runs on the Go guard but is the Pro subscription). */
async function accountTrialEndsAt(
  userId: string,
  deps: AppleAccountTokenDependencies,
  status: { readonly planId: string; readonly billingSource: PersonalBillingSource },
): Promise<Date | null> {
  if (!deps.trial || status.billingSource !== "apple" || status.planId !== "go") return null;
  return await deps.trial.activeTrialEndsAt(userId).catch(() => null);
}

/** The account's plan as the app shows it: a free trial is Pro with its trial limits. */
function currentPlanBody(
  status: { readonly planId: string; readonly billingSource: PersonalBillingSource; readonly manageUrl?: string | null },
  trialEndsAt: Date | null,
): AppleAccountTokenResponse["currentPlan"] {
  return {
    planId: trialEndsAt ? "pro" : status.planId,
    source: status.billingSource,
    ...(status.manageUrl ? { manageUrl: status.manageUrl } : {}),
    ...(trialEndsAt ? { trial: { endsAt: trialEndsAt.toISOString(), limits: TRIAL_LIMITS } } : {}),
  };
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
    purchasesGrant: purchasesGrant(app, user.primaryEmailVerified ? user.primaryEmail : null, deps.env ?? process.env),
  });
  const plans: PersonalPlanId[] = goEnabled ? ["go", "pro", "max"] : ["pro", "max"];
  const { bundleId } = app;
  const products = bundleId && reason !== "purchases_unavailable"
    ? plans.flatMap((planId) => APPLE_PLAN_BILLING_PERIODS[planId]
      .filter((billingPeriod) => (app.billingPeriods ?? ["monthly"]).includes(billingPeriod))
      .map((billingPeriod) => ({ productId: appleProductId(bundleId, planId, billingPeriod), planId, billingPeriod })))
    : [];
  const [trialEligible, trialEndsAt] = await Promise.all([
    accountTrialEligible(user.id, { deps, bundleIdHeader: app.bundleIdHeader ?? null, purchasable: reason === null, status }),
    accountTrialEndsAt(user.id, deps, status),
  ]);
  const paywall = deps.paywall
    ? await deps.paywall(user, {
      bundleIdHeader: app.bundleIdHeader ?? null,
      purchasable: reason === null && products.length > 0,
      currentPlanId: status.planId,
      supportedLayouts: app.paywallLayouts,
      trialEligible,
    })
    : undefined;
  const offer = trialEligible && paywall?.variant === TRIAL_PAYWALL_VARIANT ? trialOffer() : null;
  return {
    appAccountToken,
    eligible: reason === null,
    reason,
    currentPlan: currentPlanBody(status, trialEndsAt),
    products: offer ? [...products, { productId: offer.productId, planId: "pro", billingPeriod: "monthly" }] : products,
    planFacts: planFacts(plans),
    ...(paywall ? { paywall } : {}),
    ...(isAdminUser({ ...user, isAnonymous: false }) ? { staff: true as const } : {}),
    ...(offer ? { trial: offer } : {}),
  };
}
