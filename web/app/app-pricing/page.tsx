import { cache, Suspense } from "react";
import { headers } from "next/headers";
import { connection } from "next/server";
import { redirect, unstable_rethrow } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "../lib/stack";
import { preferredLocaleFromAcceptLanguage } from "../../i18n/accept-language";
import { loadMessages } from "../../i18n/messages";
import { routing, type Locale } from "../../i18n/routing";
import {
  FREE_PLAN_ID,
  PRO_PLAN_ID,
  isDevelopmentProAccessEnabled,
  resolveProPlanStatus,
} from "../../services/billing/pro";
import { isGoPlanEnabled } from "../../services/billing/goPlanFlag";
import {
  PricingIntervalProvider,
  PricingView,
} from "../components/pricing-checkout";
import { billingInterval } from "../../services/billing/plans";
import {
  AppPricingContent,
  type AppPlanSnapshot,
  type AppPricingMessages,
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
    <Suspense fallback={<AppPricingFallback />}>
      <RequestPricing searchParams={searchParams} />
    </Suspense>
  );
}

async function RequestPricing({
  searchParams,
}: {
  searchParams: Promise<PricingQuery>;
}) {
  const params = await searchParams;
  const interval = billingInterval(firstParam(params.interval));
  const app = Array.isArray(params.cmux_app)
    ? params.cmux_app[0]
    : params.cmux_app;
  if (app !== "1") redirect("/pricing");
  const headersList = await headers();
  const locale = supportedLocale(
    preferredLocaleFromAcceptLanguage(headersList.get("accept-language") ?? ""),
  );
  const catalog = await loadMessages(locale) as unknown as {
    pricing: AppPricingMessages;
  };
  const pricing = catalog.pricing;
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
    <Suspense
      fallback={<AppPricingContent {...fallback} pricing={pricing} section={section} />}
    >
      <PersonalizedPricing
        params={params}
        headersList={headersList}
        section={section}
        pricing={pricing}
      />
    </Suspense>
  );
  return (
    <PricingView surface="app_pricing" interval={interval}>
      <PricingIntervalProvider initialInterval={interval}>
        <AppPricingContent
          {...fallback}
          pricing={pricing}
          personalization={{
            individual: personalize("individual"),
            team: personalize("team"),
            comparison: personalize("comparison"),
            banner: personalize("banner"),
          }}
        />
      </PricingIntervalProvider>
    </PricingView>
  );
}

const pricingState = cache(async () => {
  // Keep the flag provider in the request-bound stream; its SDK dependencies
  // use runtime clocks that Next cannot safely prerender.
  await connection();
  const snapshot = await currentPlanSnapshot();
  const goPlanEnabled =
    !snapshot.isPro && (await isGoPlanEnabled(snapshot.userId));
  return { snapshot, goPlanEnabled };
});

async function PersonalizedPricing({
  params,
  headersList,
  section,
  pricing,
}: {
  params: PricingQuery;
  headersList: Headers;
  section: "individual" | "team" | "comparison" | "banner";
  pricing: AppPricingMessages;
}) {
  return (
    <AppPricingContent
      params={params}
      headersList={headersList}
      {...await pricingState()}
      section={section}
      pricing={pricing}
    />
  );
}

function supportedLocale(locale: string): Locale {
  return routing.locales.find((candidate) => candidate === locale)
    ?? routing.defaultLocale;
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

  // Stack uses a clock internally; this account lookup belongs to the live request.
  await connection();
  const user = await getStackServerApp().getUser({ or: ANONYMOUS_IF_EXISTS });
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
    email: user.primaryEmail,
  };
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
