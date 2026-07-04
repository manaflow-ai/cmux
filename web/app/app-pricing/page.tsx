import type { CSSProperties } from "react";
import { getStackServerApp, isStackConfigured } from "../lib/stack";
import { FREE_PLAN_ID, resolveProPlanStatus } from "../../services/billing/pro";
import enMessages from "../../messages/en.json";
import {
  APP_PRICING_CHECKOUT_URL,
  APP_PRICING_TEAM_CHECKOUT_URL,
} from "../lib/billing";
import { DOWNLOAD_CONFIRMATION_HREF } from "../lib/download";
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

const ENTERPRISE_CTA_URL = "/enterprise";
const pricing = enMessages.pricing;
const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

export const dynamic = "force-dynamic";

export default async function AppPricingPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const snapshot = await currentPlanSnapshot();
  const params = await searchParams;
  const banner = appPricingBanner(params);
  const appearance = appPricingAppearance(params);
  const pageBackground = appPricingPageBackground(params, appearance);
  const proFeatures = visibleProFeatures({
    base: pricing.pro.features,
    vault: pricing.pro.vaultFeatures,
    hostedNetworking: pricing.pro.hostedNetworkingFeatures,
  });
  const compareRows = visibleCompareRows(pricing.compare.rows as CompareRow[]);
  const sizeRows = pricing.sizes.rows as SizeRow[];
  const faqItems = visibleFaqItems(pricing.faq.items as FaqItem[]);

  return (
    <>
      <style>{`
        html, body {
          background: ${pageBackground} !important;
        }
      `}</style>
      <main
        className="min-h-screen w-full px-6 py-10 text-foreground sm:py-12"
        data-app-pricing-appearance={appearance}
        style={appPricingStyle(appearance, pageBackground)}
      >
        <div className="mx-auto w-full max-w-6xl">
          {banner ? <BillingBanner banner={banner} /> : null}

          <h1 className="text-2xl font-medium tracking-tight">{pricing.title}</h1>

          <div className="mt-10 grid items-stretch gap-5 md:grid-cols-2 lg:grid-cols-4">
            <PlanCard
              name={pricing.free.name}
              price={pricing.free.price}
              period={pricing.perMonth}
              badge={
                snapshot.planId === FREE_PLAN_ID ? (
                  <CurrentPlanBadge>Current plan</CurrentPlanBadge>
                ) : null
              }
            >
              {snapshot.planId === FREE_PLAN_ID ? (
                <DisabledButton>Current plan</DisabledButton>
              ) : (
                <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF}>
                  {pricing.free.cta}
                </PrimaryLink>
              )}
              <p className="mt-5 text-sm font-medium text-muted">
                {pricing.free.featuresLead}
              </p>
              <FeatureList items={pricing.free.features} muted />
            </PlanCard>

            <PlanCard
              name={pricing.pro.name}
              price={pricing.pro.price}
              period={pricing.perMonth}
              badge={
                snapshot.isPro ? (
                  <CurrentPlanBadge>Current plan</CurrentPlanBadge>
                ) : null
              }
            >
              {snapshot.isPro ? (
                <DisabledButton>Current plan</DisabledButton>
              ) : (
                <PrimaryLink href={APP_PRICING_CHECKOUT_URL}>{pricing.pro.cta}</PrimaryLink>
              )}
              <p className="mt-5 text-sm font-medium">
                {pricing.pro.featuresLead}
              </p>
              <FeatureList items={proFeatures} />
            </PlanCard>

            <PlanCard
              name={pricing.team.name}
              price={pricing.team.price}
              period={pricing.perUserMonth}
            >
              <PrimaryLink href={APP_PRICING_TEAM_CHECKOUT_URL}>{pricing.team.cta}</PrimaryLink>
              <p className="mt-5 text-sm font-medium">
                {pricing.team.featuresLead}
              </p>
              <FeatureList items={pricing.team.features} />
            </PlanCard>

            <PlanCard
              name={pricing.enterprise.name}
              price={pricing.enterprise.price}
            >
              <SecondaryLink href={ENTERPRISE_CTA_URL}>
                {pricing.enterprise.cta}
              </SecondaryLink>
              <p className="mt-5 text-sm font-medium">
                {pricing.enterprise.featuresLead}
              </p>
              <FeatureList items={pricing.enterprise.features} />
            </PlanCard>
          </div>

          <section className="mt-16">
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
                pro: `${pricing.pro.price}${pricing.perMonth}`,
                team: `${pricing.team.price}${pricing.perUserMonth}`,
                enterprise: pricing.enterprise.price,
              }}
              actions={{
                free:
                  snapshot.planId === FREE_PLAN_ID ? (
                    <DisabledButton size="compact">Current plan</DisabledButton>
                  ) : (
                    <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF} size="compact">
                      {pricing.free.cta}
                    </PrimaryLink>
                  ),
                pro: snapshot.isPro ? (
                  <DisabledButton size="compact">Current plan</DisabledButton>
                ) : (
                  <PrimaryLink href={APP_PRICING_CHECKOUT_URL} size="compact">
                    {pricing.pro.cta}
                  </PrimaryLink>
                ),
                team: (
                  <PrimaryLink href={APP_PRICING_TEAM_CHECKOUT_URL} size="compact">
                    {pricing.team.cta}
                  </PrimaryLink>
                ),
                enterprise: (
                  <SecondaryLink href={ENTERPRISE_CTA_URL} size="compact">
                    {pricing.enterprise.cta}
                  </SecondaryLink>
                ),
              }}
            />
          </section>

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
  email: string | null;
};

async function currentPlanSnapshot(): Promise<AppPlanSnapshot> {
  if (!isStackConfigured()) {
    return { authenticated: false, planId: FREE_PLAN_ID, isPro: false, email: null };
  }

  const user = await getStackServerApp().getUser({ or: ANONYMOUS_IF_EXISTS });
  if (!user) {
    return { authenticated: false, planId: FREE_PLAN_ID, isPro: false, email: null };
  }

  const status = await resolveProPlanStatus(user);
  return {
    authenticated: !user.isAnonymous,
    planId: status.planId,
    isPro: status.isPro,
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
  if (welcome === "pending") {
    return {
      message: pricing.welcomePending,
      action: { href: "/api/billing/confirm", label: pricing.welcomePendingAction },
    };
  }
  if (billing === "error") {
    return { message: pricing.billingError };
  }
  if (billing === "unavailable") {
    return { message: pricing.billingUnavailable };
  }
  return null;
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
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
            className="underline underline-offset-2 decoration-border transition-colors hover:decoration-foreground"
          >
            {banner.action.label}
          </a>
        </>
      ) : null}
    </div>
  );
}

function appPricingAppearance(
  params: Record<string, string | string[] | undefined>,
): "light" | "dark" {
  return firstParam(params.appearance) === "dark" ? "dark" : "light";
}

function appPricingPageBackground(
  params: Record<string, string | string[] | undefined>,
  appearance: "light" | "dark",
): string {
  const background = firstParam(params.background);
  if (background && /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(background)) {
    return background;
  }
  return appearance === "dark" ? "#272822" : "#fafafa";
}

function appPricingStyle(
  appearance: "light" | "dark",
  pageBackground: string,
): CSSProperties {
  if (appearance === "dark") {
    return {
      "--foreground": "#ededed",
      "--muted": "#a3a3a3",
      "--border": "rgba(255, 255, 255, 0.18)",
      "--code-bg": "rgba(24, 24, 24, 0.72)",
      "--background": pageBackground,
      "--pricing-sticky-bg": pageBackground,
      "--button-foreground": pageBackground,
      backgroundColor: pageBackground,
      colorScheme: "dark",
    } as CSSProperties;
  }
  return {
    "--foreground": "#171717",
    "--muted": "#5f6368",
    "--border": "rgba(0, 0, 0, 0.14)",
    "--code-bg": "rgba(245, 245, 245, 0.78)",
    "--background": pageBackground,
    "--pricing-sticky-bg": pageBackground,
    "--button-foreground": "#ffffff",
    backgroundColor: pageBackground,
    colorScheme: "light",
  } as CSSProperties;
}
