import { PricingAudienceSelector } from "../components/pricing-audience-selector";
import type { ReactNode } from "react";
import { headers } from "next/headers";
import { connection, NextRequest } from "next/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "../lib/stack";
import { validatedNativeCallbackScheme } from "../lib/native-callback";
import {
  FREE_PLAN_ID,
  isDevelopmentProAccessEnabled,
  MAX_PLAN_ID,
  GO_PLAN_ID,
  PRO_PLAN_ID,
  resolveProPlanStatus,
} from "../../services/billing/pro";
import enMessages from "../../messages/en.json";
import {
  appPricingCheckoutURL,
  isAppStoreDistributionMode,
  withExternalBrowserIntent,
} from "../lib/billing";
import {
  CHECKOUT_CLIENT_PARAM,
  CHECKOUT_SOURCE_APP_PRICING,
  CHECKOUT_SOURCE_PARAM,
  checkoutAttributionParamsFrom,
} from "../../services/analytics/checkoutAttribution";
import { DOWNLOAD_CONFIRMATION_HREF } from "../lib/download";
import {
  appPricingTheme,
  appPricingStyle,
} from "./appearance";
import {
  CurrentPlanBadge,
  DisabledButton,
  FeatureList,
  PlanCard,
  PricingCategorySection,
  PricingCompareTable,
  PrimaryLink,
  SecondaryLink,
  visibleCompareRows,
  visibleFaqItems,
  visibleProFeatures,
  type CompareRow,
  type FaqItem,
} from "../components/pricing-shared";
import {
  PricingCheckoutButton,
  PricingView,
} from "../components/pricing-checkout";
import {
  MAX_PRICING_USD,
  GO_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
} from "../../services/billing/plans";
import { isVaultEnabled } from "../../services/vault/config";
import { isGoPlanEnabled } from "../../services/billing/goPlanFlag";

const ENTERPRISE_CTA_URL = withExternalBrowserIntent("/enterprise");
const pricing = enMessages.pricing;
const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
const HOSTED_NETWORKING_ENABLED = false;


// oxlint-disable-next-line complexity -- Embedded pricing must keep plan actions, native return state, and App Store gating together.
export default async function AppPricingPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  if (firstParam(params.cmux_app) !== "1") redirect("/pricing");

  const headersList = await headers();
  const snapshot = await currentPlanSnapshot();
  const goPlanEnabled = await isGoPlanEnabled();
  const canManageBilling = snapshot.billingManagement === "stripe";
  // Max satisfies every "is Pro" check, so the Pro card must not call a Max
  // subscriber's plan current; only the Max card does.
  const isMax = snapshot.planId === MAX_PLAN_ID;
  const isGo = snapshot.planId === GO_PLAN_ID;
  const isProCurrent = snapshot.isPro && !isMax && !isGo;
  const requestOrigin = appPricingRequestOrigin(headersList);
  const cmuxScheme = validatedNativeCallbackScheme(
    firstParam(params.cmux_scheme),
    appPricingRequest(headersList),
  );
  const appStorePaymentGated = isAppStoreDistributionMode(params);
  const proAction = personalPlanActionState({
    isCurrent: isProCurrent,
    appStorePaymentGated,
    manageBilling: (canManageBilling && !isGo) || isMax,
  });
  // A Pro subscriber keeps the Max checkout link; the server routes an active
  // Pro subscription to the Stripe portal upgrade flow.
  const maxAction = personalPlanActionState({
    isCurrent: isMax,
    appStorePaymentGated,
    manageBilling: canManageBilling && !snapshot.isPro,
  });
  const portalVisible = canManageBilling && !appStorePaymentGated;
  // The app that opened this page tags it with the button it came from and
  // its release channel; forward that to checkout. An app build that predates
  // the tags still counts as an app-originated checkout.
  const attribution = {
    [CHECKOUT_SOURCE_PARAM]: CHECKOUT_SOURCE_APP_PRICING,
    [CHECKOUT_CLIENT_PARAM]: appStorePaymentGated ? "ios" : "mac",
    ...checkoutAttributionParamsFrom(params),
  };
  const proCheckoutHref = appPricingCheckoutURL("pro", requestOrigin, cmuxScheme, "month", attribution);
  const teamCheckoutHref = appPricingCheckoutURL("team", requestOrigin, cmuxScheme, "month", attribution);
  // Max is monthly only: one checkout link, no interval parameter.
  const maxCheckoutHref = appPricingCheckoutURL(
    "max",
    requestOrigin,
    cmuxScheme,
    undefined,
    attribution,
  );
  const maxComparePrice = `$${MAX_PRICING_USD.month.billedAmount} ${pricing.perMonth}`;
  const signInHref = appPricingSignInHref(cmuxScheme, params);
  const banner = appPricingBanner(params, snapshot, signInHref);
  const theme = appPricingTheme(params);
  const featureVisibility = {
    vault: isVaultEnabled(),
    hostedNetworking: HOSTED_NETWORKING_ENABLED,
  };
  const proFeatures = visibleProFeatures({
    base: pricing.pro.features,
    vault: pricing.pro.vaultFeatures,
    hostedNetworking: pricing.pro.hostedNetworkingFeatures,
    visibility: featureVisibility,
  });
  const compareRows = visibleCompareRows(
    pricing.compare.rows as CompareRow[],
    featureVisibility,
  );
  const faqItems = visibleFaqItems(
    pricing.faq.items as FaqItem[],
    featureVisibility,
  );
  const teamMonthlyComparePrice = pricingMessage(
    pricing.teamMonthlyComparePrice,
    { monthly: TEAM_PRICING_USD.month.monthlyEquivalent },
  );

  return (
    <>
      <style>{`
        html, body {
          background: ${theme.background} !important;
        }
      `}</style>
      <main
        className="min-h-screen w-full px-6 py-10 text-foreground sm:py-12"
        data-cmux-app-theme="true"
        data-cmux-app-theme-appearance={theme.appearance}
        data-app-pricing-appearance={theme.appearance}
        style={appPricingStyle(theme)}
      >
        <div className="mx-auto w-full max-w-6xl">
          {banner ? <BillingBanner banner={banner} /> : null}

          <PricingView surface="app_pricing">
            <h1 className="text-2xl font-medium tracking-tight">{pricing.title}</h1>


          <PricingAudienceSelector
            individualLabel={pricing.audience.individual}
            teamLabel={pricing.audience.team}
            ariaLabel={pricing.audience.label}
            surface="app_pricing"
            individual={
<PricingCategorySection
            showHeading={false}
            id="individual-pricing-category"
              title={pricing.categories.individual.title}
              description={pricing.categories.individual.description}
              columns={goPlanEnabled ? "four" : "three"}
            >
              <PlanCard
                name={pricing.free.name}
                price={pricing.free.price}
                period={pricing.perMonth}
                badge={
                  snapshot.authenticated && snapshot.planId === FREE_PLAN_ID ? (
                    <CurrentPlanBadge>{pricing.currentPlan}</CurrentPlanBadge>
                  ) : null
                }
              >
                {!snapshot.authenticated ? (
                  <SecondaryLink href={signInHref}>
                    {pricing.signedOutSignIn}
                  </SecondaryLink>
                ) : snapshot.planId === FREE_PLAN_ID ? (
                  <DisabledButton>{pricing.currentPlan}</DisabledButton>
                ) : (
                  <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF}>
                    {pricing.free.cta}
                  </PrimaryLink>
                )}
                <p className="mt-5 text-sm font-medium">
                  {pricing.free.featuresLead}
                </p>
                <FeatureList items={pricing.free.features} />
              </PlanCard>

              {goPlanEnabled ? <PlanCard
                name={pricing.go.name}
                price={`$${GO_PRICING_USD.month.billedAmount}`}
                period={pricing.perMonth}
                badge={isGo ? <CurrentPlanBadge>{pricing.currentPlan}</CurrentPlanBadge> : null}
              >
                {isGo ? (
                  <div className="space-y-2">
                    <DisabledButton>{pricing.currentPlan}</DisabledButton>
                    {portalVisible ? <SecondaryLink href="/api/billing/portal">{pricing.manageBilling}</SecondaryLink> : null}
                  </div>
                ) : appStorePaymentGated ? (
                  <DisabledButton>{pricing.billingUnavailable}</DisabledButton>
                ) : (
                  <PricingCheckoutButton
                    href={appPricingCheckoutURL("go", requestOrigin, cmuxScheme, "month", attribution)}
                    location="app_pricing"
                    plan="go"
                  >
                    {pricing.go.cta}
                  </PricingCheckoutButton>
                )}
                <p className="mt-5 text-sm font-medium">{pricing.go.featuresLead}</p>
                <FeatureList items={pricing.go.features} />
              </PlanCard> : null}

              <PlanCard
                name={pricing.pro.name}
                price={`$${PRO_PRICING_USD.month.billedAmount}`}
                period={pricing.perMonth}
                badge={
                  isProCurrent ? (
                    <CurrentPlanBadge>{pricing.currentPlan}</CurrentPlanBadge>
                  ) : null
                }
              >
                <PersonalPlanAction
                  state={proAction}
                  portalVisible={portalVisible}
                  checkout={
                    <PricingCheckoutButton
                      href={proCheckoutHref}
                      location="app_pricing"
                    >
                      {pricing.pro.cta}
                    </PricingCheckoutButton>
                  }
                />
                <p className="mt-5 text-sm font-medium">
                  {pricing.pro.featuresLead}
                </p>
                <FeatureList items={proFeatures} />
              </PlanCard>

              {/* Max: larger machines on the monthly personal plan. */}
              <PlanCard
                name={pricing.max.name}
                price={`$${MAX_PRICING_USD.month.billedAmount}`}
                period={pricing.perMonth}
                badge={
                  isMax ? (
                    <CurrentPlanBadge>{pricing.currentPlan}</CurrentPlanBadge>
                  ) : null
                }
              >
                <PersonalPlanAction
                  state={maxAction}
                  portalVisible={portalVisible}
                  checkout={
                    <PricingCheckoutButton
                      href={maxCheckoutHref}
                      location="app_pricing"
                      plan="max"
                    >
                      {pricing.max.cta}
                    </PricingCheckoutButton>
                  }
                />
                <p className="mt-5 text-sm font-medium">
                  {pricing.max.featuresLead}
                </p>
                <FeatureList items={pricing.max.features} />
              </PlanCard>

            </PricingCategorySection>
            }
            team={
<PricingCategorySection
            showHeading={false}
            id="team-enterprise-pricing-category"
              title={pricing.categories.business.title}
              description={pricing.categories.business.description}
              columns="two"
            >
              <PlanCard
                name={pricing.team.name}
                price={`$${TEAM_PRICING_USD.month.billedAmount}`}
                period={pricing.perUserMonth}
              >
                {appStorePaymentGated ? (
                  <DisabledButton>{pricing.billingUnavailable}</DisabledButton>
                ) : (
                  <PricingCheckoutButton
                    href={teamCheckoutHref}
                    location="app_pricing"
                    plan="team"
                  >
                    {pricing.team.cta}
                  </PricingCheckoutButton>
                )}
                <p className="mt-5 text-sm font-medium">
                  {pricing.team.featuresLead}
                </p>
                <FeatureList items={pricing.team.features} />
              </PlanCard>

              <PlanCard
                name={pricing.enterprise.name}
                price={pricing.enterprise.price}
              >
                {appStorePaymentGated ? (
                  <DisabledButton>{pricing.billingUnavailable}</DisabledButton>
                ) : (
                  <SecondaryLink href={ENTERPRISE_CTA_URL}>
                    {pricing.enterprise.cta}
                  </SecondaryLink>
                )}
                <p className="mt-5 text-sm font-medium">
                  {pricing.enterprise.featuresLead}
                </p>
                <FeatureList items={pricing.enterprise.features} />
              </PlanCard>
            </PricingCategorySection>
            }
          />

          <section className="mt-16">
            <h2 className="mb-5 text-lg font-medium tracking-tight">
              {pricing.compare.title}
            </h2>
            <PricingCompareTable
              rows={compareRows}
              showGo={goPlanEnabled}
              stickyTopClassName="top-0"
              names={{
                free: pricing.free.name,
                go: pricing.go.name,
                pro: pricing.pro.name,
                max: pricing.max.name,
                team: pricing.team.name,
                enterprise: pricing.enterprise.name,
              }}
              prices={{
                free: pricing.free.price,
                go: `$${GO_PRICING_USD.month.billedAmount} ${pricing.perMonth}`,
                pro: `$${PRO_PRICING_USD.month.billedAmount} ${pricing.perMonth}`,
                max: maxComparePrice,
                team: teamMonthlyComparePrice,
                enterprise: pricing.enterprise.price,
              }}
            />
          </section>
          </PricingView>

          <section className="mt-16 border-t border-border pt-10">
            <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
              {pricing.faq.title}
            </h2>
            <div className="max-w-2xl space-y-5 text-[15px] leading-relaxed">
              {faqItems.map((item, i) => (
                <div key={i}>
                  <p className="mb-1 font-medium">{item.q}</p>
                  <p className="text-muted">{item.a}</p>
                </div>
              ))}
            </div>
          </section>
        </div>
      </main>
    </>
  );
}

type AppPlanSnapshot = {
  authenticated: boolean;
  developmentPro: boolean;
  planId: string;
  isPro: boolean;
  billingManagement: "stripe" | "none";
  email: string | null;
};

async function currentPlanSnapshot(): Promise<AppPlanSnapshot> {
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
    authenticated: !user.isAnonymous,
    developmentPro: false,
    planId: status.planId,
    isPro: status.isPro,
    billingManagement: status.billingManagement,
    email: user.primaryEmail,
  };
}

type PersonalPlanActionState = "current" | "unavailable" | "manage" | "checkout";

/** Which action a personal plan card (Pro, Max) offers the signed-in account. */
function personalPlanActionState({
  isCurrent,
  appStorePaymentGated,
  manageBilling,
}: {
  isCurrent: boolean;
  appStorePaymentGated: boolean;
  manageBilling: boolean;
}): PersonalPlanActionState {
  if (isCurrent) return "current";
  // Apple 3.1.1: no external billing or purchase links inside App Store builds.
  if (appStorePaymentGated) return "unavailable";
  if (manageBilling) return "manage";
  return "checkout";
}

function PersonalPlanAction({
  state,
  portalVisible,
  checkout,
}: {
  state: PersonalPlanActionState;
  portalVisible: boolean;
  checkout: ReactNode;
}) {
  switch (state) {
    case "current":
      return (
        <div className="space-y-2">
          <DisabledButton>{pricing.currentPlan}</DisabledButton>
          {portalVisible ? (
            <SecondaryLink href="/api/billing/portal">
              {pricing.manageBilling}
            </SecondaryLink>
          ) : null}
        </div>
      );
    case "unavailable":
      return <DisabledButton>{pricing.billingUnavailable}</DisabledButton>;
    case "manage":
      return (
        <SecondaryLink href="/api/billing/portal">
          {pricing.manageBilling}
        </SecondaryLink>
      );
    case "checkout":
      return checkout;
  }
}

type BillingBannerModel = {
  message: string;
  action?: { href: string; label: string };
};

/// In-webview sign-in that also signs the native app in: Stack sign-in sets
/// the webview's session cookies, then /handler/after-sign-in hands tokens to
/// the app through its <scheme>://auth-callback URL. The stateless callback is
/// accepted by the app's fallback path (HostBrowserSignInFlow.handleCallbackURL).
/// web_return_to lets the embedded browser navigate back to this pricing page
/// (with its appearance params intact) once the app has consumed the callback.
function appPricingSignInHref(
  cmuxScheme: string,
  params: Record<string, string | string[] | undefined>,
): string {
  const search = new URLSearchParams();
  for (const [name, value] of Object.entries(params)) {
    const first = firstParam(value);
    if (first !== null) search.set(name, first);
  }
  const query = search.toString();
  const webReturnTo = query ? `/app-pricing?${query}` : "/app-pricing";
  const afterSignIn =
    `/handler/after-sign-in?native_app_return_to=${encodeURIComponent(
      `${cmuxScheme}://auth-callback`,
    )}&web_return_to=${encodeURIComponent(webReturnTo)}`;
  return `/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}`;
}

function appPricingBanner(
  params: Record<string, string | string[] | undefined>,
  snapshot: AppPlanSnapshot,
  signInHref: string,
): BillingBannerModel | null {
  const welcome = firstParam(params.welcome);
  const billing = firstParam(params.billing);

  if (welcome === "success") {
    return { message: pricing.welcomeSuccess };
  }
  if (welcome === "active") {
    return { message: pricing.welcomeActive };
  }
  if (welcome === "team") {
    return { message: pricing.welcomeTeam };
  }
  if (billing === "error") {
    return { message: pricing.billingError };
  }
  if (billing === "unavailable") {
    return { message: pricing.billingUnavailable };
  }
  if (billing === "cancelled") {
    return { message: pricing.billingCancelled };
  }
  if (billing === "annual_unavailable") return { message: pricing.billingAnnualUnavailable };
  if (billing === "plan_unavailable") return { message: pricing.billingPlanUnavailable };
  if (billing === "invalid_plan") {
    return { message: pricing.billingInvalidPlan };
  }
  if (billing === "invalid_relay") {
    return { message: pricing.billingInvalidRelay };
  }
  if (snapshot.developmentPro) {
    return null;
  }
  if (!snapshot.authenticated) {
    return {
      message: pricing.signedOutNotice,
      action: { href: signInHref, label: pricing.signedOutSignIn },
    };
  }
  return null;
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

function pricingMessage(
  message: string,
  values: Record<string, string | number>,
): string {
  return message.replace(/\{(\w+)\}/g, (match, key: string) => {
    const value = values[key];
    return value === undefined ? match : String(value);
  });
}

function BillingBanner({ banner }: { banner: BillingBannerModel }) {
  return (
    <div
      role="status"
      className="mb-8 border border-border bg-code-bg px-4 py-3 text-sm"
    >
      {banner.message}
      {banner.action ? (
        <>
          {" "}
          <a
            href={banner.action.href}
            className="underline underline-offset-2 decoration-link-underline transition-colors hover:decoration-foreground"
          >
            {banner.action.label}
          </a>
        </>
      ) : null}
    </div>
  );
}

function appPricingRequestOrigin(headersList: Headers): string | null {
  const forwardedHost = firstHeaderValue(headersList.get("x-forwarded-host"));
  const host = forwardedHost ?? firstHeaderValue(headersList.get("host"));
  if (!host) return null;
  const forwardedProto = firstHeaderValue(headersList.get("x-forwarded-proto"));
  const proto = forwardedProto ?? (isLoopbackHost(host) ? "http" : "https");
  if (proto !== "http" && proto !== "https") return null;
  return `${proto}://${host}`;
}

function appPricingRequest(headersList: Headers): NextRequest {
  return new NextRequest(appPricingRequestOrigin(headersList) ?? "https://cmux.com", {
    headers: headersList,
  });
}

function firstHeaderValue(value: string | null): string | null {
  const first = value?.split(",")[0]?.trim();
  return first && first.length > 0 ? first : null;
}

function isLoopbackHost(host: string): boolean {
  const hostname = host.startsWith("[")
    ? host.slice(1, host.indexOf("]")).toLowerCase()
    : host.split(":")[0]?.toLowerCase();
  return hostname === "localhost" || hostname === "127.0.0.1" || hostname === "::1";
}
