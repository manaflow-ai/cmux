import type { ReactNode } from "react";
import { notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "../../../components/site-header";
import { FeatureList, PlanCard, PrimaryLink, SecondaryLink } from "../../../../components/pricing-shared";
import {
  NEXT_PLANS,
  NEXT_PLAN_CONTACT_EMAIL,
  NEXT_PLAN_TRANSFER_HREF,
  nextPlanActionHref,
  type NextPlan,
} from "../../../../../services/billing/nextPlans";
import { NEXT_PRO_PLAN_ID } from "../../../../../services/billing/plans";
import { isNextPricingPreviewEnabled } from "../../../../../services/billing/nextPricingPreview";

/** Preview page: never indexed, never linked from the live site. */
export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "nextPricing" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    robots: { index: false, follow: false },
  };
}

type FaqItem = { q: string; a: string };

const usd = (value: number) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(value);

const linkClass = "underline underline-offset-2";

/** A `t.rich` tag renderer that wraps its text in a mail link. */
function emailLink(href: string) {
  return function EmailLink(chunks: ReactNode) {
    return (
      <a href={href} className={linkClass}>
        {chunks}
      </a>
    );
  };
}

export default async function NextPricingPage({ params }: { params: Promise<{ locale: string }> }) {
  if (!isNextPricingPreviewEnabled()) notFound();
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "nextPricing" });

  const card = (plan: NextPlan) => {
    const Action = plan.id === NEXT_PRO_PLAN_ID ? PrimaryLink : SecondaryLink;
    return (
      <PlanCard key={plan.id} name={t(`plans.${plan.id}.name`)} price={usd(plan.monthlyUsd)} period={t("perMonth")}>
        <Action href={nextPlanActionHref(plan.id)}>{t(`plans.${plan.id}.cta`)}</Action>
        <div className="mt-5 border-l border-foreground pl-3">
          <p className="text-sm font-medium">{t("includedUsage", { amount: usd(plan.includedUsageUsd) })}</p>
        </div>
        <FeatureList items={t.raw(`plans.${plan.id}.features`) as string[]} />
      </PlanCard>
    );
  };

  const faq = t.raw("faq.items") as FaqItem[];

  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="mx-auto w-full max-w-4xl px-6 py-16 sm:py-20">
        <div className="mb-8 border border-dashed border-border px-4 py-3 text-sm" role="note">
          <span className="font-medium">{t("previewBadge")}</span>
          <span className="text-muted">{` · ${t("previewNote")}`}</span>
        </div>

        <p className="text-sm font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-2 max-w-3xl text-3xl font-medium tracking-tight sm:text-4xl">{t("title")}</h1>
        <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-muted">{t("lede")}</p>

        <div className="mt-12 grid items-stretch gap-5 md:grid-cols-2">{NEXT_PLANS.map(card)}</div>
        <p className="mt-4 text-sm text-muted">
          {t.rich("checkoutNote", { email: NEXT_PLAN_CONTACT_EMAIL, link: emailLink(nextPlanActionHref(NEXT_PRO_PLAN_ID)) })}
        </p>

        <section
          className="mt-12 border border-border px-5 py-4"
          aria-labelledby="next-classic-transfer-title"
          data-testid="next-classic-transfer"
        >
          <h2 id="next-classic-transfer-title" className="text-sm font-medium">
            {t("classic.title")}
          </h2>
          <p className="mt-2 text-[15px] leading-relaxed text-muted">{t("classic.body")}</p>
          <p className="mt-2 text-[15px] leading-relaxed">
            {t.rich("classic.transfer", { email: NEXT_PLAN_CONTACT_EMAIL, link: emailLink(NEXT_PLAN_TRANSFER_HREF) })}
          </p>
        </section>

        <section className="mt-16 border-t border-border pt-10">
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">{t("faq.title")}</h2>
          <div className="max-w-2xl space-y-5 text-[15px]" style={{ lineHeight: 1.5 }}>
            {faq.map((item) => (
              <div key={item.q}>
                <p className="mb-1 font-medium">{item.q}</p>
                <p className="text-muted">{item.a}</p>
              </div>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}
