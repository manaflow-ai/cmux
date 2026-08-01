import { headers } from "next/headers";
import { NextRequest } from "next/server";
import { redirect } from "next/navigation";
import { getStackServerApp, isStackConfigured } from "../lib/stack";
import { validatedNativeCallbackScheme } from "../lib/native-callback";
import { FREE_PLAN_ID, resolveProPlanStatus } from "../../services/billing/pro";
import enMessages from "../../messages/en.json";
import {
  appPricingCheckoutURL,
  isAppStoreDistributionMode,
  withExternalBrowserIntent,
} from "../lib/billing";
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
  PricingCompareTable,
  PricingSizeTable,
  PrimaryLink,
  SecondaryLink,
  visibleCompareRows,
  visibleFaqItems,
  visibleProFeatures,
  type CompareRow,
  type FaqItem,
  type SizeRow,
} from "../components/pricing-shared";
import {
  PricingCheckoutButton,
  PricingIntervalProvider,
  PricingIntervalSelector,
  PricingIntervalValue,
} from "../components/pricing-interval-selector";
import {
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../../services/billing/plans";

const ENTERPRISE_CTA_URL = withExternalBrowserIntent("/enterprise");
const pricing = enMessages.pricing;
const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

export const dynamic = "force-dynamic";

export default async function AppPricingPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  if (firstParam(params.cmux_app) !== "1") redirect("/pricing");

  const snapshot = await currentPlanSnapshot();
  const headersList = await headers();
  const requestOrigin = appPricingRequestOrigin(headersList);
  const cmuxScheme = validatedNativeCallbackScheme(
    firstParam(params.cmux_scheme),
    appPricingRequest(headersList),
  );
  const appStorePaymentGated = isAppStoreDistributionMode(params);
  const interval = proBillingInterval(firstParam(params.interval));
  const proCheckoutHrefs = {
    month: appPricingCheckoutURL("pro", requestOrigin, cmuxScheme, "month"),
    year: appPricingCheckoutURL("pro", requestOrigin, cmuxScheme, "year"),
  };
  const teamCheckoutHrefs = {
    month: appPricingCheckoutURL("team", requestOrigin, cmuxScheme, "month"),
    year: appPricingCheckoutURL("team", requestOrigin, cmuxScheme, "year"),
  };
  const banner = appPricingBanner(params);
  const theme = appPricingTheme(params);
  const proFeatures = visibleProFeatures({
    base: pricing.pro.features,
    vault: pricing.pro.vaultFeatures,
    hostedNetworking: pricing.pro.hostedNetworkingFeatures,
  });
  const compareRows = visibleCompareRows(pricing.compare.rows as CompareRow[]);
  const sizeRows = pricing.sizes.rows as SizeRow[];
  const faqItems = visibleFaqItems(pricing.faq.items as FaqItem[]);
  const annualComparePrice = pricingMessage(pricing.annualComparePrice, {
    monthly: PRO_PRICING_USD.year.monthlyEquivalent,
    annual: PRO_PRICING_USD.year.billedAmount,
  });
  const teamMonthlyComparePrice = pricingMessage(
    pricing.teamMonthlyComparePrice,
    { monthly: TEAM_PRICING_USD.month.monthlyEquivalent },
  );
  const teamAnnualComparePrice = pricingMessage(
    pricing.teamAnnualComparePrice,
    {
      monthly: TEAM_PRICING_USD.year.monthlyEquivalent,
      annual: TEAM_PRICING_USD.year.billedAmount,
    },
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

          <PricingIntervalProvider initialInterval={interval}>
            <h1 className="text-2xl font-medium tracking-tight">{pricing.title}</h1>
            <PricingIntervalSelector
              billingPeriodLabel={pricing.billingPeriod}
              monthlyLabel={pricing.monthly}
              annualLabel={pricing.annual}
              savingsLabel={pricingMessage(pricing.saveAnnual, {
                discount: PRO_PRICING_USD.year.discountPercent,
              })}
              surface="app_pricing"
            />

            <div className="mt-6 grid items-stretch gap-5 sm:grid-cols-2 min-[1800px]:grid-cols-4">
              <PlanCard
                name={pricing.free.name}
                price={pricing.free.price}
                period={pricing.perMonth}
                badge={
                  snapshot.planId === FREE_PLAN_ID ? (
                    <CurrentPlanBadge>{pricing.currentPlan}</CurrentPlanBadge>
                  ) : null
                }
              >
                {snapshot.planId === FREE_PLAN_ID ? (
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

              <PlanCard
                name={pricing.pro.name}
                price={
                  <PricingIntervalValue
                    monthly={pricing.pro.price}
                    annual={`$${PRO_PRICING_USD.year.monthlyEquivalent}`}
                  />
                }
                period={
                  <PricingIntervalValue
                    monthly={pricing.perMonth}
                    annual={pricing.perMonthBilledYearly}
                  />
                }
                priceDetail={
                  <PricingIntervalValue
                    monthly={null}
                    annual={
                      <p className="mt-2 text-sm text-muted">
                        {pricingMessage(pricing.annualPriceDetail, {
                          amount: PRO_PRICING_USD.year.billedAmount,
                          discount: PRO_PRICING_USD.year.discountPercent,
                        })}
                      </p>
                    }
                  />
                }
                badge={
                  snapshot.isPro ? (
                    <CurrentPlanBadge>{pricing.currentPlan}</CurrentPlanBadge>
                  ) : null
                }
              >
                {snapshot.isPro ? (
                  <div className="space-y-2">
                    <DisabledButton>{pricing.currentPlan}</DisabledButton>
                    {appStorePaymentGated ? null : (
                      <SecondaryLink href="/api/billing/portal">
                        {pricing.manageBilling}
                      </SecondaryLink>
                    )}
                  </div>
                ) : appStorePaymentGated ? (
                  <DisabledButton>{pricing.billingUnavailable}</DisabledButton>
                ) : (
                  <PricingCheckoutButton
                    hrefs={proCheckoutHrefs}
                    location="app_pricing"
                  >
                    {pricing.pro.cta}
                  </PricingCheckoutButton>
                )}
                <p className="mt-5 text-sm font-medium">
                  {pricing.pro.featuresLead}
                </p>
                <FeatureList items={proFeatures} />
              </PlanCard>

              <PlanCard
                name={pricing.team.name}
                price={
                  <PricingIntervalValue
                    monthly={pricing.team.price}
                    annual={`$${TEAM_PRICING_USD.year.monthlyEquivalent}`}
                  />
                }
                period={
                  <PricingIntervalValue
                    monthly={pricing.perUserMonth}
                    annual={pricing.perUserMonthBilledYearly}
                  />
                }
                priceDetail={
                  <PricingIntervalValue
                    monthly={null}
                    annual={
                      <p className="mt-2 text-sm text-muted">
                        {pricingMessage(pricing.annualPriceDetail, {
                          amount: TEAM_PRICING_USD.year.billedAmount,
                          discount: TEAM_PRICING_USD.year.discountPercent,
                        })}
                      </p>
                    }
                  />
                }
              >
                {appStorePaymentGated ? (
                  <DisabledButton>{pricing.billingUnavailable}</DisabledButton>
                ) : (
                  <PricingCheckoutButton
                    hrefs={teamCheckoutHrefs}
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
            </div>

          <section className="mt-16">
            <h2 className="mb-5 text-lg font-medium tracking-tight">
              {pricing.compare.title}
            </h2>
            <PricingCompareTable
              rows={compareRows}
              stickyTopClassName="top-0"
              names={{
                free: pricing.free.name,
                pro: pricing.pro.name,
                team: pricing.team.name,
                enterprise: pricing.enterprise.name,
              }}
              prices={{
                free: pricing.free.price,
                pro: (
                  <PricingIntervalValue
                    monthly={`${pricing.pro.price} ${pricing.perMonth}`}
                    annual={annualComparePrice}
                  />
                ),
                team: (
                  <PricingIntervalValue
                    monthly={teamMonthlyComparePrice}
                    annual={teamAnnualComparePrice}
                  />
                ),
                enterprise: pricing.enterprise.price,
              }}
            />
          </section>
          </PricingIntervalProvider>

          <PricingSizeTable
            rows={sizeRows}
            title={pricing.sizes.title}
            body={pricing.sizes.body}
            colSize={pricing.sizes.colSize}
            colUse={pricing.sizes.colUse}
            colRate={pricing.sizes.colRate}
          />

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
  planId: string;
  isPro: boolean;
  billingManagement: "stripe" | "none";
  email: string | null;
};

async function currentPlanSnapshot(): Promise<AppPlanSnapshot> {
  if (!isStackConfigured()) {
    return {
      authenticated: false,
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      email: null,
    };
  }

  const user = await getStackServerApp().getUser({ or: ANONYMOUS_IF_EXISTS });
  if (!user) {
    return {
      authenticated: false,
      planId: FREE_PLAN_ID,
      isPro: false,
      billingManagement: "none",
      email: null,
    };
  }

  const status = await resolveProPlanStatus(user);
  return {
    authenticated: !user.isAnonymous,
    planId: status.planId,
    isPro: status.isPro,
    billingManagement: status.billingManagement,
    email: user.primaryEmail,
  };
}

type BillingBannerModel = {
  message: string;
  action?: { href: string; label: string };
};

function appPricingBanner(
  params: Record<string, string | string[] | undefined>,
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
  if (billing === "invalid_plan") {
    return { message: pricing.billingInvalidPlan };
  }
  if (billing === "invalid_relay") {
    return { message: pricing.billingInvalidRelay };
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
