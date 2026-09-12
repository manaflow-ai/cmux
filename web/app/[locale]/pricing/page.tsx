import { getTranslations } from "next-intl/server";
import { Suspense } from "react";
import { SiteHeader } from "../components/site-header";
import { Link } from "../../../i18n/navigation";
import { ProCtaLink } from "../components/pro-cta-link";
import { ProWelcomeBanner } from "../components/pro-welcome-banner";
import {
  MAX_CHECKOUT_URL,
  PRO_CHECKOUT_URL,
  TEAM_CHECKOUT_URL,
  withCheckoutInterval,
} from "../../lib/billing";
import {
  CHECKOUT_SOURCE_PARAM,
  CHECKOUT_SOURCE_PRICING_PAGE,
  checkoutAttributionParamsFrom,
  withCheckoutAttribution,
} from "../../../services/analytics/checkoutAttribution";
import { DOWNLOAD_CONFIRMATION_HREF } from "../../lib/download";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import {
  MAX_PLAN_ID,
  resolveProPlanStatus,
} from "../../../services/billing/pro";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "../../../i18n/seo";
import { pricingSeoCopy } from "../../../i18n/audited-seo";
import {
  fallbackContentLocales,
  hasFallbackContent,
} from "../../../i18n/locale-availability";
import {
  CurrentPlanBadge,
  DisabledButton,
  FeatureList,
  PlanCard,
  PricingCompareTable,
  PrimaryLink,
  SecondaryLink,
  visibleCompareRows,
  visibleFaqItems,
  visibleProFeatures,
  type CompareRow,
  type FaqItem,
} from "../../components/pricing-shared";
import {
  PricingCheckoutButton,
  PricingIntervalProvider,
  PricingIntervalSelector,
  PricingIntervalValue,
} from "../../components/pricing-interval-selector";
import {
  MAX_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
  proBillingInterval,
} from "../../../services/billing/plans";
import { isVaultEnabled } from "../../../services/vault/config";

const ENTERPRISE_CTA_URL = "/enterprise";
const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;
const HOSTED_NETWORKING_ENABLED = false;


export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "pricing" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const contentLocale = hasFallbackContent(locale) ? locale : "en";
  const { title, description } = pricingSeoCopy(
    contentLocale,
    t,
    siteMeta,
    isVaultEnabled() ? "metaDescription" : "metaDescriptionNoVault",
  );
  const alternates = buildAlternates(
    contentLocale,
    "/pricing",
    fallbackContentLocales,
  );
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(contentLocale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(contentLocale, title, description),
  };
}

export default async function PricingPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { locale } = await params;
  const query = searchParams ? await searchParams : {};
  const t = await getTranslations({ locale, namespace: "pricing" });
  const snapshot = await currentPlanSnapshot();
  const canManageBilling = snapshot.billingManagement === "stripe";
  // Max satisfies every "is Pro" check, so the Pro card must not call a Max
  // subscriber's plan current; only the Max card does.
  const isMax = snapshot.planId === MAX_PLAN_ID;
  const isProCurrent = snapshot.isPro && !isMax;
  const interval = proBillingInterval(firstParam(query.interval) ?? "year");
  // A link into /pricing may name its own origin (the CLI trial notice, a
  // campaign with utm_* tags); that beats the page default so the checkout
  // is attributed to the surface that sent the visitor here.
  const attribution = {
    [CHECKOUT_SOURCE_PARAM]: CHECKOUT_SOURCE_PRICING_PAGE,
    ...checkoutAttributionParamsFrom(query),
  };
  const proCheckoutURL = withCheckoutAttribution(PRO_CHECKOUT_URL, attribution);
  const teamCheckoutURL = withCheckoutAttribution(TEAM_CHECKOUT_URL, attribution);
  // Max is monthly only: one checkout link, no interval parameter.
  const maxCheckoutHref = withCheckoutAttribution(MAX_CHECKOUT_URL, attribution);
  const proCheckoutHrefs = {
    month: withCheckoutInterval(proCheckoutURL, "month"),
    year: withCheckoutInterval(proCheckoutURL, "year"),
  };
  const teamCheckoutHrefs = {
    month: withCheckoutInterval(teamCheckoutURL, "month"),
    year: withCheckoutInterval(teamCheckoutURL, "year"),
  };
  const annualComparePrice = t("annualComparePrice", {
    monthly: PRO_PRICING_USD.year.monthlyEquivalent,
  });
  const maxComparePrice = `$${MAX_PRICING_USD.month.billedAmount} ${t("perMonth")}`;
  const teamMonthlyComparePrice = t("teamMonthlyComparePrice", {
    monthly: TEAM_PRICING_USD.month.monthlyEquivalent,
  });
  const teamAnnualComparePrice = t("teamAnnualComparePrice", {
    monthly: TEAM_PRICING_USD.year.monthlyEquivalent,
  });

  const freeFeatures = t.raw("free.features") as string[];
  const proBaseFeatures = t.raw("pro.features") as string[];
  const proVaultFeatures = t.raw("pro.vaultFeatures") as string[];
  const proNetworkingFeatures = t.raw("pro.hostedNetworkingFeatures") as string[];
  const featureVisibility = {
    vault: isVaultEnabled(),
    hostedNetworking: HOSTED_NETWORKING_ENABLED,
  };
  const proFeatures = visibleProFeatures({
    base: proBaseFeatures,
    vault: proVaultFeatures,
    hostedNetworking: proNetworkingFeatures,
    visibility: featureVisibility,
  });
  const maxFeatures = t.raw("max.features") as string[];
  const teamFeatures = t.raw("team.features") as string[];
  const enterpriseFeatures = t.raw("enterprise.features") as string[];
  const compareRows = visibleCompareRows(
    t.raw("compare.rows") as CompareRow[],
    featureVisibility,
  );
  const faqItems = visibleFaqItems(
    t.raw("faq.items") as FaqItem[],
    featureVisibility,
  );

  const linkClass =
    "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

  return (
    <div className="min-h-screen">
      <SiteHeader />

      <main className="w-full max-w-6xl mx-auto px-6 py-16 sm:py-20">
        {/* Post-checkout / billing states from /api/billing/checkout */}
        <Suspense fallback={null}>
          <ProWelcomeBanner />
        </Suspense>

        <PricingIntervalProvider initialInterval={interval}>
          {/* Title */}
          <h1 className="text-2xl font-medium tracking-tight">{t("title")}</h1>
          <PricingIntervalSelector
            billingPeriodLabel={t("billingPeriod")}
            monthlyLabel={t("monthly")}
            annualLabel={t("annual")}
            savingsLabel={t("saveAnnual", {
              discount: PRO_PRICING_USD.year.discountPercent,
            })}
            surface="public_pricing"
          />

          {/* Tier cards */}
          <div className="mt-6 grid gap-5 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 items-stretch">
            {/* Free */}
            <PlanCard
              name={t("free.name")}
              price={t("free.price")}
              period={t("perMonth")}
            >
              <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF}>{t("free.cta")}</PrimaryLink>
              <p className="mt-5 text-sm font-medium">
                {t("free.featuresLead")}
              </p>
              <FeatureList items={freeFeatures} />
            </PlanCard>

            {/* Pro */}
            <PlanCard
              name={t("pro.name")}
              price={
                <PricingIntervalValue
                  monthly={`$${PRO_PRICING_USD.month.billedAmount}`}
                  annual={`$${PRO_PRICING_USD.year.monthlyEquivalent}`}
                />
              }
              period={
                <PricingIntervalValue
                  monthly={t("perMonth")}
                  annual={t("perMonthBilledYearly")}
                />
              }
              badge={
                isProCurrent ? (
                  <CurrentPlanBadge>{t("currentPlan")}</CurrentPlanBadge>
                ) : null
              }
            >
              {isProCurrent ? (
                <div className="space-y-2">
                  <DisabledButton>{t("currentPlan")}</DisabledButton>
                  <SecondaryLink href="/api/billing/portal">
                    {t("manageBilling")}
                  </SecondaryLink>
                </div>
              ) : canManageBilling || isMax ? (
                <SecondaryLink href="/api/billing/portal">
                  {t("manageBilling")}
                </SecondaryLink>
              ) : (
                <ProCtaLink checkoutHrefs={proCheckoutHrefs}>
                  {t("pro.cta")}
                </ProCtaLink>
              )}
              <p className="mt-5 text-sm font-medium">{t("pro.featuresLead")}</p>
              <FeatureList items={proFeatures} />
            </PlanCard>

            {/* Max: monthly only, so the interval selector never changes it.
                A Pro subscriber sees checkout; the server routes an active
                Pro subscription to the Stripe portal upgrade flow. */}
            <PlanCard
              name={t("max.name")}
              price={`$${MAX_PRICING_USD.month.billedAmount}`}
              period={t("perMonth")}
              badge={
                isMax ? (
                  <CurrentPlanBadge>{t("currentPlan")}</CurrentPlanBadge>
                ) : null
              }
            >
              {isMax ? (
                <div className="space-y-2">
                  <DisabledButton>{t("currentPlan")}</DisabledButton>
                  <SecondaryLink href="/api/billing/portal">
                    {t("manageBilling")}
                  </SecondaryLink>
                </div>
              ) : canManageBilling && !snapshot.isPro ? (
                <SecondaryLink href="/api/billing/portal">
                  {t("manageBilling")}
                </SecondaryLink>
              ) : (
                <PricingCheckoutButton
                  hrefs={maxCheckoutHref}
                  location="pricing_page"
                  plan="max"
                >
                  {t("max.cta")}
                </PricingCheckoutButton>
              )}
              <p className="mt-5 text-sm font-medium">{t("max.featuresLead")}</p>
              <FeatureList items={maxFeatures} />
            </PlanCard>

            {/* Team */}
            <PlanCard
              name={t("team.name")}
              price={
                <PricingIntervalValue
                  monthly={`$${TEAM_PRICING_USD.month.billedAmount}`}
                  annual={`$${TEAM_PRICING_USD.year.monthlyEquivalent}`}
                />
              }
              period={
                <PricingIntervalValue
                  monthly={t("perUserMonth")}
                  annual={t("perUserMonthBilledYearly")}
                />
              }
            >
              <PricingCheckoutButton
                hrefs={teamCheckoutHrefs}
                location="pricing_page"
                plan="team"
              >
                {t("team.cta")}
              </PricingCheckoutButton>
              <p className="mt-5 text-sm font-medium">{t("team.featuresLead")}</p>
              <FeatureList items={teamFeatures} />
            </PlanCard>

            {/* Enterprise */}
            <PlanCard
              name={t("enterprise.name")}
              price={t("enterprise.price")}
            >
              <SecondaryLink href={ENTERPRISE_CTA_URL}>
                {t("enterprise.cta")}
              </SecondaryLink>
              <p className="mt-5 text-sm font-medium">
                {t("enterprise.featuresLead")}
              </p>
              <FeatureList items={enterpriseFeatures} />
            </PlanCard>
          </div>

          <p className="mt-6 text-sm text-muted">
            <Link
              href="/billing/recover"
              className="underline underline-offset-2 decoration-link-underline hover:text-foreground"
            >
              {t("alreadyPaid")}
            </Link>
          </p>

          {/* Compare plans. Header row is sticky under the 48px h-12 site header.
              Horizontal scrolling is mobile-only so desktop keeps the page as the
              sticky scroll container. */}
          <section className="mt-16">
            <PricingCompareTable
              rows={compareRows}
              names={{
                free: t("free.name"),
                pro: t("pro.name"),
                max: t("max.name"),
                team: t("team.name"),
                enterprise: t("enterprise.name"),
              }}
              prices={{
                free: t("free.price"),
                pro: (
                  <PricingIntervalValue
                    monthly={`$${PRO_PRICING_USD.month.billedAmount} ${t("perMonth")}`}
                    annual={annualComparePrice}
                  />
                ),
                max: maxComparePrice,
                team: (
                  <PricingIntervalValue
                    monthly={teamMonthlyComparePrice}
                    annual={teamAnnualComparePrice}
                  />
                ),
                enterprise: t("enterprise.price"),
              }}
              actions={{
                free: (
                  <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF} size="compact">
                    {t("free.cta")}
                  </PrimaryLink>
                ),
                pro: (
                  isProCurrent ? (
                    <DisabledButton size="compact">{t("currentPlan")}</DisabledButton>
                  ) : canManageBilling || isMax ? (
                    <SecondaryLink href="/api/billing/portal" size="compact">
                      {t("manageBilling")}
                    </SecondaryLink>
                  ) : (
                    <ProCtaLink
                      checkoutHrefs={proCheckoutHrefs}
                      size="compact"
                      location="pricing_compare_header"
                    >
                      {t("pro.cta")}
                    </ProCtaLink>
                  )
                ),
                max: (
                  isMax ? (
                    <DisabledButton size="compact">{t("currentPlan")}</DisabledButton>
                  ) : canManageBilling && !snapshot.isPro ? (
                    <SecondaryLink href="/api/billing/portal" size="compact">
                      {t("manageBilling")}
                    </SecondaryLink>
                  ) : (
                    <PricingCheckoutButton
                      hrefs={maxCheckoutHref}
                      location="pricing_compare_header"
                      plan="max"
                      size="compact"
                    >
                      {t("max.cta")}
                    </PricingCheckoutButton>
                  )
                ),
                team: (
                  <PricingCheckoutButton
                    hrefs={teamCheckoutHrefs}
                    location="pricing_compare_header"
                    plan="team"
                    size="compact"
                  >
                    {t("team.cta")}
                  </PricingCheckoutButton>
                ),
                enterprise: (
                  <SecondaryLink href={ENTERPRISE_CTA_URL} size="compact">
                    {t("enterprise.cta")}
                  </SecondaryLink>
                ),
              }}
            />
          </section>
        </PricingIntervalProvider>

        {/* FAQ */}
        <section className="mt-16 border-t border-border pt-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("faq.title")}
          </h2>
          <div
            className="space-y-5 text-[15px] max-w-2xl"
            style={{ lineHeight: 1.5 }}
          >
            {faqItems.map((item, i) => (
              <div key={i}>
                <p className="font-medium mb-1">{item.q}</p>
                <p className="text-muted">{item.a}</p>
              </div>
            ))}
          </div>
          <p className="mt-8 text-[15px] text-muted">
            {t.rich("help", {
              discord: (chunks) => (
                <a
                  href="https://discord.gg/xsgFEVrWCZ"
                  target="_blank"
                  rel="noopener noreferrer"
                  className={linkClass}
                >
                  {chunks}
                </a>
              ),
              github: (chunks) => (
                <a
                  href="https://github.com/manaflow-ai/cmux"
                  target="_blank"
                  rel="noopener noreferrer"
                  className={linkClass}
                >
                  {chunks}
                </a>
              ),
              email: (chunks) => (
                <a href="mailto:founders@manaflow.ai" className={linkClass}>
                  {chunks}
                </a>
              ),
            })}
          </p>
        </section>
      </main>
    </div>
  );
}

type PlanSnapshot = {
  planId: "free" | "pro" | "max";
  isPro: boolean;
  billingManagement: "stripe" | "none";
};

async function currentPlanSnapshot(): Promise<PlanSnapshot> {
  if (!isStackConfigured()) {
    return { planId: "free", isPro: false, billingManagement: "none" };
  }

  const user = await getStackServerApp().getUser({ or: ANONYMOUS_IF_EXISTS });
  if (!user) {
    return { planId: "free", isPro: false, billingManagement: "none" };
  }

  const status = await resolveProPlanStatus(user);
  return {
    planId: status.planId,
    isPro: status.isPro,
    billingManagement: status.billingManagement,
  };
}

function firstParam(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}
