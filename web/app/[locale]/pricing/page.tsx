import { getTranslations } from "next-intl/server";
import { Suspense } from "react";
import { SiteHeader } from "../components/site-header";
import { ProCtaLink } from "../components/pro-cta-link";
import { ProWelcomeBanner } from "../components/pro-welcome-banner";
import { PRO_CHECKOUT_URL, TEAM_CHECKOUT_URL } from "../../lib/billing";
import { DOWNLOAD_CONFIRMATION_HREF } from "../../lib/download";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { resolveProPlanStatus } from "../../../services/billing/pro";
import { buildAlternates } from "../../../i18n/seo";
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
  SHOW_VAULT,
  type CompareRow,
  type FaqItem,
  type SizeRow,
} from "../../components/pricing-shared";

// The Pro CTA destination is decided at runtime by the proCheckout PostHog
// flag inside <ProCtaLink> (see app/lib/feature-flags.ts); the download
// link is the safe fallback.
const ENTERPRISE_CTA_URL = "/enterprise";
const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

export const dynamic = "force-dynamic";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "pricing" });
  return {
    title: t("metaTitle"),
    description: SHOW_VAULT ? t("metaDescription") : t("metaDescriptionNoVault"),
    alternates: buildAlternates(locale, "/pricing"),
  };
}

export default async function PricingPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "pricing" });
  const snapshot = await currentPlanSnapshot();

  const freeFeatures = t.raw("free.features") as string[];
  const proBaseFeatures = t.raw("pro.features") as string[];
  const proVaultFeatures = t.raw("pro.vaultFeatures") as string[];
  const proNetworkingFeatures = t.raw("pro.hostedNetworkingFeatures") as string[];
  const proFeatures = visibleProFeatures({
    base: proBaseFeatures,
    vault: proVaultFeatures,
    hostedNetworking: proNetworkingFeatures,
  });
  const teamFeatures = t.raw("team.features") as string[];
  const enterpriseFeatures = t.raw("enterprise.features") as string[];
  const compareRows = visibleCompareRows(t.raw("compare.rows") as CompareRow[]);
  const sizeRows = t.raw("sizes.rows") as SizeRow[];
  const faqItems = visibleFaqItems(t.raw("faq.items") as FaqItem[]);

  const linkClass =
    "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";

  return (
    <div className="min-h-screen">
      <SiteHeader />

      <main className="w-full max-w-6xl mx-auto px-6 py-16 sm:py-20">
        {/* Post-checkout / billing states from /api/billing/checkout|confirm */}
        <Suspense fallback={null}>
          <ProWelcomeBanner />
        </Suspense>

        {/* Title */}
        <h1 className="text-2xl font-medium tracking-tight">{t("title")}</h1>

        {/* Tier cards */}
        <div className="mt-10 grid gap-5 md:grid-cols-2 lg:grid-cols-4 items-stretch">
          {/* Free */}
          <PlanCard
            name={t("free.name")}
            price={t("free.price")}
            period={t("perMonth")}
          >
            <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF}>{t("free.cta")}</PrimaryLink>
            <p className="mt-5 text-sm font-medium text-muted">
              {t("free.featuresLead")}
            </p>
            <FeatureList items={freeFeatures} muted />
          </PlanCard>

          {/* Pro */}
          <PlanCard
            name={t("pro.name")}
            price={t("pro.price")}
            period={t("perMonth")}
            badge={
              snapshot.isPro ? (
                <CurrentPlanBadge>{t("currentPlan")}</CurrentPlanBadge>
              ) : null
            }
          >
            {snapshot.isPro ? (
              <div className="space-y-2">
                <DisabledButton>{t("currentPlan")}</DisabledButton>
                <SecondaryLink href="/api/billing/portal">
                  {t("manageBilling")}
                </SecondaryLink>
              </div>
            ) : (
              <ProCtaLink checkoutHref={PRO_CHECKOUT_URL} fallbackHref={DOWNLOAD_CONFIRMATION_HREF}>
                {t("pro.cta")}
              </ProCtaLink>
            )}
            <p className="mt-5 text-sm font-medium">{t("pro.featuresLead")}</p>
            <FeatureList items={proFeatures} />
          </PlanCard>

          {/* Team */}
          <PlanCard
            name={t("team.name")}
            price={t("team.price")}
            period={t("perUserMonth")}
          >
            <PrimaryLink href={TEAM_CHECKOUT_URL}>{t("team.cta")}</PrimaryLink>
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

        {/* Compare plans. Header row is sticky under the 48px h-12 site header.
            No overflow-x wrapper: an overflow container becomes a scroll context
            on both axes and would anchor the sticky header to itself instead of
            the page. */}
        <section className="mt-16">
          <PricingCompareTable
            rows={compareRows}
            names={{
              free: t("free.name"),
              pro: t("pro.name"),
              team: t("team.name"),
              enterprise: t("enterprise.name"),
            }}
            prices={{
              free: t("free.price"),
              pro: `${t("pro.price")}${t("perMonth")}`,
              team: `${t("team.price")}${t("perUserMonth")}`,
              enterprise: t("enterprise.price"),
            }}
            actions={{
              free: (
                <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF} size="compact">
                  {t("free.cta")}
                </PrimaryLink>
              ),
              pro: (
                snapshot.isPro ? (
                  <DisabledButton size="compact">{t("currentPlan")}</DisabledButton>
                ) : (
                  <ProCtaLink
                    checkoutHref={PRO_CHECKOUT_URL}
                    fallbackHref={DOWNLOAD_CONFIRMATION_HREF}
                    size="compact"
                    location="pricing_compare_header"
                  >
                    {t("pro.cta")}
                  </ProCtaLink>
                )
              ),
              team: (
                <PrimaryLink href={TEAM_CHECKOUT_URL} size="compact">
                  {t("team.cta")}
                </PrimaryLink>
              ),
              enterprise: (
                <SecondaryLink href={ENTERPRISE_CTA_URL} size="compact">
                  {t("enterprise.cta")}
                </SecondaryLink>
              ),
            }}
          />
        </section>

        {/* Cloud VM sizes */}
        <PricingSizeTable
          rows={sizeRows}
          title={t("sizes.title")}
          body={t("sizes.body")}
          colSize={t("sizes.colSize")}
          colUse={t("sizes.colUse")}
          colRate={t("sizes.colRate")}
        />

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

async function currentPlanSnapshot(): Promise<{ isPro: boolean }> {
  if (!isStackConfigured()) {
    return { isPro: false };
  }

  const user = await getStackServerApp().getUser({ or: ANONYMOUS_IF_EXISTS });
  if (!user) {
    return { isPro: false };
  }

  const status = await resolveProPlanStatus(user);
  return { isPro: status.isPro };
}
