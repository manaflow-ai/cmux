import { notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "../../../components/site-header";
import { DOWNLOAD_CONFIRMATION_HREF } from "../../../../lib/download";
import {
  FeatureList,
  PlanCard,
  PrimaryLink,
  SecondaryLink,
} from "../../../../components/pricing-shared";
import {
  CHIEF_MODELS,
  CHIEF_PLANS,
  SANDBOX_LIST_USD,
  blendedUsdPerMillion,
  chiefModel,
  sandboxHourUsd,
  type ChiefPlan,
  type ChiefPlanId,
} from "../../../../../services/billing/chiefPricing";
import { isNextPricingPreviewEnabled } from "../../../../../services/billing/nextPricingPreview";
import { ChiefPricingCalculator } from "./chief-pricing-calculator";

/** Proposal page: never indexed, never linked from the live site. */
export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "nextPricing" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    robots: { index: false, follow: false },
  };
}

type Pillar = { title: string; body: string };
type CompareRow = { product: string; plan: string; included: string; sandbox: string };
type FaqItem = { q: string; a: string };

const usd = (value: number, digits = 0) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);

const rate = (value: number) =>
  new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 4 }).format(value);

const PLAN_ACTION_HREF: Record<ChiefPlanId, string> = {
  free: DOWNLOAD_CONFIRMATION_HREF,
  // Proposal only: the paid buttons go to the live pricing page, never to a new Stripe price.
  pro: "/pricing",
  max: "/pricing",
  team: "/pricing",
  enterprise: "/enterprise",
};

export default async function NextPricingPage({ params }: { params: Promise<{ locale: string }> }) {
  if (!isNextPricingPreviewEnabled()) notFound();
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "nextPricing" });

  const kimi = blendedUsdPerMillion(chiefModel("kimi-k2.7-code"));
  const standardSandbox = { vcpu: 2, gib: 4 };
  const sandboxHour = sandboxHourUsd(standardSandbox);

  const planName = (id: ChiefPlanId) => t(`plans.${id}.name`);
  const planNames = Object.fromEntries(CHIEF_PLANS.map((p) => [p.id, planName(p.id)])) as Record<ChiefPlanId, string>;

  const card = (plan: ChiefPlan) => {
    const price = plan.monthlyUsd === null ? t("custom") : usd(plan.monthlyUsd);
    const period = plan.monthlyUsd === null || plan.monthlyUsd === 0 ? undefined : plan.perSeat ? t("perSeatMonth") : t("perMonth");
    const Action = plan.id === "free" || plan.id === "pro" ? PrimaryLink : SecondaryLink;
    return (
      <PlanCard
        key={plan.id}
        name={planName(plan.id)}
        price={price}
        period={period}
        badge={plan.id === "pro" ? <span className="border border-border px-2 py-1 text-xs font-medium">{t("mostPopular")}</span> : null}
      >
        {plan.annualMonthlyUsd !== null ? (
          <p className="mb-3 text-xs text-muted">{t("billedYearly", { price: usd(plan.annualMonthlyUsd) })}</p>
        ) : null}
        <Action href={PLAN_ACTION_HREF[plan.id]}>{t(`plans.${plan.id}.cta`)}</Action>
        {plan.includedCreditsUsd > 0 ? (
          <div className="mt-5 border-l border-foreground pl-3">
            <p className="text-sm font-medium">
              {t(plan.perSeat ? "includedCreditsSeat" : "includedCredits", { amount: usd(plan.includedCreditsUsd) })}
            </p>
            <p className="mt-1 text-xs text-muted tabular-nums">
              {t("includedTokens", {
                tokens: Math.round(plan.includedCreditsUsd / kimi).toLocaleString("en-US"),
                hours: Math.floor(plan.includedCreditsUsd / sandboxHour).toLocaleString("en-US"),
              })}
            </p>
          </div>
        ) : null}
        <FeatureList items={t.raw(`plans.${plan.id}.features`) as string[]} />
      </PlanCard>
    );
  };

  const pillars = t.raw("pillars") as Pillar[];
  const compareRows = t.raw("compare.rows") as CompareRow[];
  const faq = t.raw("faq.items") as FaqItem[];

  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="mx-auto w-full max-w-6xl px-6 py-16 sm:py-20">
        <div className="mb-8 border border-dashed border-border px-4 py-3 text-sm" role="note">
          <span className="font-medium">{t("previewBadge")}</span>
          <span className="text-muted">{` · ${t("previewNote")}`}</span>
        </div>

        <p className="text-sm font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-2 max-w-3xl text-3xl font-medium tracking-tight sm:text-4xl">{t("title")}</h1>
        <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-muted">{t("lede")}</p>

        <div className="mt-10 grid gap-5 md:grid-cols-3">
          {pillars.map((pillar) => (
            <div key={pillar.title} className="border-l border-border pl-4">
              <p className="text-sm font-medium">{pillar.title}</p>
              <p className="mt-1 text-sm leading-relaxed text-muted">{pillar.body}</p>
            </div>
          ))}
        </div>

        <div className="mt-12 grid items-stretch gap-5 md:grid-cols-3">
          {CHIEF_PLANS.filter((p) => !p.perSeat).map(card)}
        </div>
        <div className="mt-5 grid items-stretch gap-5 md:grid-cols-2">
          {CHIEF_PLANS.filter((p) => p.perSeat).map(card)}
        </div>

        <ChiefPricingCalculator
          labels={{
            title: t("calculator.title"),
            turns: t("calculator.turns"),
            tokensPerTurn: t("calculator.tokensPerTurn"),
            workdays: t("calculator.workdays"),
            model: t("calculator.model"),
            openModels: t("calculator.openModels"),
            frontierModels: t("calculator.frontierModels"),
            sandboxHours: t("calculator.sandboxHours"),
            sandboxSize: t("calculator.sandboxSize"),
            parallel: t("calculator.parallel"),
            seats: t("calculator.seats"),
            tokens: t("calculator.tokens"),
            tokenCost: t("calculator.tokenCost"),
            sandboxCost: t.raw("calculator.sandboxCost") as string,
            usage: t("calculator.usage"),
            included: t("calculator.included"),
            overage: t("calculator.overage"),
            plan: t("calculator.plan"),
            total: t("calculator.total"),
            recommended: t.raw("calculator.recommended") as string,
            doesNotFit: t.raw("calculator.doesNotFit") as string,
            assumption: t("calculator.assumption"),
            custom: t("custom"),
            planNames,
          }}
        />

        <section className="mt-16" aria-labelledby="chief-rates-title">
          <h2 id="chief-rates-title" className="text-lg font-medium tracking-tight">{t("rates.title")}</h2>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[640px] border-collapse text-sm tabular-nums">
              <thead>
                <tr className="border-b border-border text-left text-muted">
                  <th className="py-2 pr-4 font-normal">{t("rates.modelHeader")}</th>
                  <th className="py-2 pr-4 text-right font-normal">{t("rates.inputHeader")}</th>
                  <th className="py-2 pr-4 text-right font-normal">{t("rates.cachedHeader")}</th>
                  <th className="py-2 pr-4 text-right font-normal">{t("rates.outputHeader")}</th>
                  <th className="py-2 text-right font-normal">{t("rates.blendedHeader")}</th>
                </tr>
              </thead>
              <tbody>
                {CHIEF_MODELS.map((model) => (
                  <tr key={model.id} className="border-b border-border">
                    <td className="py-2 pr-4">{model.label}</td>
                    <td className="py-2 pr-4 text-right">{rate(model.inputPerM)}</td>
                    <td className="py-2 pr-4 text-right">{rate(model.cachedInputPerM)}</td>
                    <td className="py-2 pr-4 text-right">{rate(model.outputPerM)}</td>
                    <td className="py-2 text-right font-medium">{usd(blendedUsdPerMillion(model), 2)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <h3 className="mt-8 text-sm font-medium">{t("rates.sandboxTitle")}</h3>
          <ul className="mt-2 grid gap-1 text-sm text-muted tabular-nums">
            <li>{`${rate(SANDBOX_LIST_USD.vcpuHourUsd)} ${t("rates.vcpuHour")}`}</li>
            <li>{`${rate(SANDBOX_LIST_USD.gibHourUsd)} ${t("rates.gbHour")}`}</li>
            <li>{`${rate(SANDBOX_LIST_USD.storageGibMonthUsd)} ${t("rates.storage")}`}</li>
          </ul>
          <p className="mt-2 text-sm">{t("rates.example", { price: usd(sandboxHour, 3) })}</p>
        </section>

        <section className="mt-16" aria-labelledby="chief-compare-title">
          <h2 id="chief-compare-title" className="text-lg font-medium tracking-tight">{t("compare.title")}</h2>
          <p className="mt-1 text-sm text-muted">{t("compare.note")}</p>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[720px] border-collapse text-sm">
              <thead>
                <tr className="border-b border-border text-left text-muted">
                  <th className="py-2 pr-4 font-normal">{t("compare.productHeader")}</th>
                  <th className="py-2 pr-4 font-normal">{t("compare.planHeader")}</th>
                  <th className="py-2 pr-4 font-normal">{t("compare.includedHeader")}</th>
                  <th className="py-2 font-normal">{t("compare.sandboxHeader")}</th>
                </tr>
              </thead>
              <tbody>
                {compareRows.map((row, index) => (
                  <tr key={row.product} className={`border-b border-border ${index === 0 ? "font-medium" : ""}`}>
                    <td className="py-2 pr-4">{row.product}</td>
                    <td className="py-2 pr-4">{row.plan}</td>
                    <td className="py-2 pr-4">{row.included}</td>
                    <td className="py-2">{row.sandbox}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
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
