import { cache, Suspense } from "react";
import { headers } from "next/headers";
import { connection } from "next/server";
import { redirect, unstable_rethrow } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "../lib/stack";
import {
  FREE_PLAN_ID,
  PRO_PLAN_ID,
  isDevelopmentProAccessEnabled,
  resolveProPlanStatus,
} from "../../services/billing/pro";
import { isGoPlanEnabled } from "../../services/billing/goPlanFlag";
import { PricingView } from "../components/pricing-checkout";
import { isAppStoreDistributionMode } from "../lib/billing";
import {
  AppPricingContent,
  appPricingRequestSignInHref,
  type AppPlanSnapshot,
} from "./pricing-content";
import { AppPricingFallback, unknownPlan } from "./pricing-fallback";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
type PricingQuery = Record<string, string | string[] | undefined>;

export default function AppPricingPage({
  searchParams,
}: {
  searchParams: Promise<PricingQuery>;
}) {
  return (
    <PricingView surface="app_pricing">
      <Suspense fallback={<AppPricingFallback />}>
        <RequestPricing searchParams={searchParams} />
      </Suspense>
    </PricingView>
  );
}

async function RequestPricing({
  searchParams,
}: {
  searchParams: Promise<PricingQuery>;
}) {
  const params = await searchParams;
  const app = Array.isArray(params.cmux_app)
    ? params.cmux_app[0]
    : params.cmux_app;
  if (app !== "1") redirect("/pricing");
  const headersList = await headers();
  // A signed-out app signs in before it sees a plan button. Checkout opens in
  // the default browser, so a purchase from here would leave the app signed
  // out, or bill a different account than the app uses.
  if (!isAppStoreDistributionMode(params) && (await isSignedOut())) {
    redirect(appPricingRequestSignInHref(params, headersList));
  }
  const fallback = {
    params,
    headersList,
    snapshot: unknownPlan,
    goPlanEnabled: false,
    pending: true,
  };
  const personalize = (
    section: "individual" | "team" | "comparison" | "banner",
  ) => (
    <Suspense fallback={<AppPricingContent {...fallback} section={section} />}>
      <PersonalizedPricing
        params={params}
        headersList={headersList}
        section={section}
      />
    </Suspense>
  );
  return (
    <AppPricingContent
      {...fallback}
      personalization={{
        individual: personalize("individual"),
        team: personalize("team"),
        comparison: personalize("comparison"),
        banner: personalize("banner"),
      }}
    />
  );
}

/** The request's account, looked up once per render. */
const requestUser = cache(async () => {
  // Stack uses a clock internally; this account lookup belongs to the live request.
  await connection();
  return getStackServerApp().getUser({ or: ANONYMOUS_IF_EXISTS });
});

/**
 * True only when the lookup worked and found no signed-in account. An outage
 * keeps the page reachable; checkout still requires an account.
 */
async function isSignedOut(): Promise<boolean> {
  if (!isStackConfigured() || isDevelopmentProAccessEnabled()) return false;
  try {
    const user = await requestUser();
    return !user || user.isAnonymous;
  } catch (error) {
    unstable_rethrow(error);
    return false;
  }
}

const pricingState = cache(async () => {
  const snapshot = await currentPlanSnapshot();
  const goPlanEnabled =
    !snapshot.isPro && (await isGoPlanEnabled(snapshot.userId));
  return { snapshot, goPlanEnabled };
});

async function PersonalizedPricing({
  params,
  headersList,
  section,
}: {
  params: PricingQuery;
  headersList: Headers;
  section: "individual" | "team" | "comparison" | "banner";
}) {
  return (
    <AppPricingContent
      params={params}
      headersList={headersList}
      {...await pricingState()}
      section={section}
    />
  );
}

/**
 * Personalization only. A Hexclave or billing outage must leave the pricing
 * page intact, so any failure renders the signed-out plan state.
 */
async function currentPlanSnapshot(): Promise<AppPlanSnapshot> {
  try {
    return await readPlanSnapshot();
  } catch (error) {
    unstable_rethrow(error);
    console.error("App pricing personalization failed", {
      errorType: error instanceof Error ? error.name : typeof error,
    });
    return {
      authenticated: false,
      developmentPro: false,
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      email: null,
    };
  }
}

async function readPlanSnapshot(): Promise<AppPlanSnapshot> {
  if (!isStackConfigured()) {
    return {
      authenticated: false,
      developmentPro: false,
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      email: null,
    };
  }

  const user = await requestUser();
  if (!user) {
    const developmentPro = isDevelopmentProAccessEnabled();
    return {
      authenticated: false,
      developmentPro,
      planId: developmentPro ? PRO_PLAN_ID : FREE_PLAN_ID,
      isPro: developmentPro,
      billingManagement: "none",
      email: null,
    };
  }

  const developmentPro = user.isAnonymous && isDevelopmentProAccessEnabled();
  if (developmentPro) {
    return {
      authenticated: false,
      developmentPro: true,
      planId: PRO_PLAN_ID,
      isPro: true,
      billingManagement: "none",
      email: null,
    };
  }

  const status = await resolveProPlanStatus(user);
  return {
    userId: user.id,
    authenticated: !user.isAnonymous,
    developmentPro: false,
    planId: status.planId,
    isPro: status.isPro,
    billingManagement: status.billingManagement,
    billingSource: status.billingSource,
    cancelScheduled: status.cancelScheduled ?? false,
    paymentPastDue: status.paymentPastDue ?? false,
    email: user.primaryEmail,
  };
}
