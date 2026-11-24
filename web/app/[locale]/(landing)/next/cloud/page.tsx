import { notFound } from "next/navigation";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "../../../components/site-header";
import { DOWNLOAD_CONFIRMATION_HREF } from "../../../../lib/download";
import { FeatureList, PlanCard, PrimaryLink } from "../../../../components/pricing-shared";
import {
  NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD,
  NEXT_STANDARD_MACHINE_MEMORY_GB,
  NEXT_STANDARD_MACHINE_VCPUS,
  cloudPlanFacts,
  type CloudPlanFacts,
} from "../../../../../services/billing/cloudPlans";
import { isNextPricingPreviewEnabled } from "../../../../../services/billing/nextPricingPreview";
import { CloudCompareBlock } from "./compare-block";

/** Preview page: never indexed, never linked from the live site. */
export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "nextCloudPlans" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    robots: { index: false, follow: false },
  };
}

const usd = (value: number, digits = 0) =>
  new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);

/** The cmux Cloud plans: every number from services/billing/cloudPlans.ts, the price book's copy. */
export default async function NextCloudPlansPage({ params }: { params: Promise<{ locale: string }> }) {
  if (!isNextPricingPreviewEnabled()) notFound();
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "nextCloudPlans" });
  const hours = new Intl.NumberFormat(locale, { maximumFractionDigits: 1 });
  const plans = cloudPlanFacts();

  const card = (plan: CloudPlanFacts) => (
    <PlanCard key={plan.id} name={plan.name} price={usd(plan.monthUsd)} period={t("perMonth")}>
      <div className="border-l border-foreground pl-3" data-testid={`cloud-plan-hours-${plan.id}`}>
        <p className="text-sm font-medium tabular-nums">{t("hours", { hours: hours.format(plan.includedHours) })}</p>
        <p className="mt-1 text-xs text-muted tabular-nums">
          {t("machine", { vcpus: NEXT_STANDARD_MACHINE_VCPUS, memory: NEXT_STANDARD_MACHINE_MEMORY_GB })}
        </p>
      </div>
      <FeatureList
        items={[
          t("after", { price: usd(NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD, 2) }),
          t("metering"),
          t("paused"),
        ]}
      />
      <p className="mt-4 text-xs text-muted">{t("models")}</p>
      <div className="pt-6">
        <PrimaryLink href={DOWNLOAD_CONFIRMATION_HREF}>{t("cta")}</PrimaryLink>
      </div>
    </PlanCard>
  );

  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="mx-auto w-full max-w-6xl px-6 py-16 sm:py-20">
        <div className="mb-8 border border-dashed border-border px-4 py-3 text-sm" role="note">
          <span className="font-medium">{t("previewBadge")}</span>
          <span className="text-muted">{` · ${t("previewNote")}`}</span>
        </div>

        <p className="text-sm font-medium text-muted">{t("title")}</p>
        <h1 className="mt-2 max-w-3xl text-3xl font-medium tracking-tight sm:text-4xl">{t("headline")}</h1>
        <p className="mt-3 max-w-2xl text-lg tracking-tight">{t("subhead")}</p>
        <p className="mt-5 max-w-2xl text-[15px] leading-relaxed text-muted">
          {t("lede", { vcpus: NEXT_STANDARD_MACHINE_VCPUS, memory: NEXT_STANDARD_MACHINE_MEMORY_GB })}
        </p>

        <div className="mt-12 grid items-stretch gap-5 md:grid-cols-3">{plans.map(card)}</div>

        <section className="mt-16" aria-labelledby="cloud-plan-table-title">
          <h2 id="cloud-plan-table-title" className="text-lg font-medium tracking-tight">
            {t("table.title")}
          </h2>
          <p className="mt-1 text-sm text-muted">{t("table.note", { price: usd(NEXT_OVERAGE_STANDARD_MACHINE_HOUR_USD, 2) })}</p>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[560px] border-collapse text-sm tabular-nums" data-testid="cloud-plan-table">
              <thead>
                <tr className="border-b border-border text-left text-muted">
                  <th className="py-2 pr-4 font-normal">{t("table.plan")}</th>
                  <th className="py-2 pr-4 text-right font-normal">{t("table.price")}</th>
                  <th className="py-2 pr-4 text-right font-normal">{t("table.keptRunning")}</th>
                  <th className="py-2 text-right font-normal">{t("table.hours")}</th>
                </tr>
              </thead>
              <tbody>
                {plans.map((plan) => (
                  <tr key={plan.id} className="border-b border-border">
                    <th scope="row" className="py-2 pr-4 text-left font-medium">{plan.name}</th>
                    <td className="py-2 pr-4 text-right">{`${usd(plan.monthUsd)} ${t("perMonth")}`}</td>
                    <td className="py-2 pr-4 text-right">{hours.format(plan.keptRunning)}</td>
                    <td className="py-2 text-right">{hours.format(plan.includedHours)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        <CloudCompareBlock t={t} />
      </main>
    </div>
  );
}
