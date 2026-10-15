"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import type { PaywallLabVariant } from "@/orpc/server/dashboard/schemas/ops";
import { ProPlanCard } from "@/app/components/pro-plan-card";
import {
  FeatureList,
  PlanCard,
  PricingCategorySection,
  PrimaryLink,
  visibleProFeatures,
} from "@/app/components/pricing-shared";
import { MAX_PRICING_USD, PRO_PRICING_USD } from "@/services/billing/plans";

type Preview = NonNullable<PaywallLabVariant["preview"]>;
type WebPresentation = Extract<Preview, { kind: "web" }>["presentation"];
type IosConfig = Extract<Preview, { kind: "ios" }>["config"];

/**
 * A `web-pricing-v1` arm as a signed-out visitor sees the top of /pricing:
 * the same title, plan cards, toggle, labels and copy, from the same
 * components and messages. It is inert: no link or button works here.
 */
export function WebPricingVariantPreview({
  presentation,
  vaultEnabled,
}: {
  readonly presentation: WebPresentation;
  readonly vaultEnabled: boolean;
}) {
  const t = useTranslations("pricing");
  const labels = {
    billingPeriod: t("billingPeriod"),
    yearly: t("pro.annual.yearly"),
    monthly: t("monthly"),
    perMonth: t("perMonth"),
  };
  const proFeatures = visibleProFeatures({
    base: t.raw("pro.features") as string[],
    vault: t.raw("pro.vaultFeatures") as string[],
    hostedNetworking: t.raw("pro.hostedNetworkingFeatures") as string[],
    visibility: { vault: vaultEnabled, hostedNetworking: false },
  });
  const hrefs = { month: "#", year: "#" };
  const highlight = (plan: "pro" | "max") =>
    presentation.highlightedPlanId === plan ? presentation.highlightLabel : null;
  return (
    <div inert className="pointer-events-none select-none bg-background p-4 text-foreground">
      <h1 className="text-2xl font-medium tracking-tight">{presentation.headline ?? t("title")}</h1>
      {presentation.subheadline ? (
        <p className="mt-2 max-w-2xl text-[15px] text-muted">{presentation.subheadline}</p>
      ) : null}
      <div className="mt-6">
        <PricingCategorySection
          showHeading={false}
          title={t("categories.individual.title")}
          description={t("categories.individual.description")}
          columns="three"
        >
          <PlanCard name={t("free.name")} price={t("free.price")} period={t("perMonth")}>
            <PrimaryLink href="#">{t("free.cta")}</PrimaryLink>
            <p className="mt-5 text-sm font-medium">{t("free.featuresLead")}</p>
            <FeatureList items={t.raw("free.features") as string[]} />
          </PlanCard>
          <ProPlanCard
            name={t("pro.name")}
            surface="paywall_lab"
            initialInterval={presentation.defaultBillingPeriod}
            labels={labels}
            checkoutHrefs={hrefs}
            requiresSignIn
            ctaLabel={t("pro.cta")}
            highlightLabel={highlight("pro")}
            yearlyNote={presentation.yearlyNote}
            pricing={PRO_PRICING_USD}
          >
            <p className="mt-5 text-sm font-medium">{t("pro.featuresLead")}</p>
            <FeatureList items={proFeatures} />
          </ProPlanCard>
          <ProPlanCard
            name={t("max.name")}
            plan="max"
            surface="paywall_lab"
            initialInterval={presentation.defaultBillingPeriod}
            labels={labels}
            checkoutHrefs={hrefs}
            requiresSignIn
            ctaLabel={t("max.cta")}
            highlightLabel={highlight("max")}
            yearlyNote={presentation.yearlyNote}
            pricing={MAX_PRICING_USD}
          >
            <p className="mt-5 text-sm font-medium">{t("max.featuresLead")}</p>
            <FeatureList items={t.raw("max.features") as string[]} />
          </ProPlanCard>
        </PricingCategorySection>
      </div>
    </div>
  );
}

/**
 * An `ios-paywall-v1` arm, drawn after the iOS paywall's three layouts
 * (BillingPaywallConfig): cards, comparison and focus. Plan names come from
 * the pricing messages; the app shows App Store prices, so none are drawn.
 */
export function IosPaywallPreview({ config }: { readonly config: IosConfig }) {
  const t = useTranslations("opsPaywallLab.ios");
  const pricing = useTranslations("pricing");
  const plans = [
    { id: "pro" as const, name: pricing("pro.name") },
    { id: "max" as const, name: pricing("max.name") },
  ];
  const highlighted = plans.find((plan) => plan.id === config.highlightedPlanId) ?? null;
  const cta = config.ctaStyle === "action" ? t("ctaAction", { plan: highlighted?.name ?? plans[0]!.name }) : t("ctaPrice");
  return (
    <div inert className="mx-auto w-[300px] select-none rounded-[28px] border border-border bg-background p-4 text-foreground">
      <p className="text-lg font-semibold leading-tight">{config.headline}</p>
      {config.subheadline ? <p className="mt-1.5 text-[13px] text-muted">{config.subheadline}</p> : null}
      {config.bullets.length > 0 ? (
        <ul className="mt-3 space-y-1 text-[13px]">
          {config.bullets.map((bullet) => <li key={bullet}>• {bullet}</li>)}
        </ul>
      ) : null}
      <PeriodPicker selected={config.defaultBillingPeriod} savings={config.showYearlySavings} />
      <IosLayout config={config} plans={plans} highlighted={highlighted?.id ?? null} />
      <div className="mt-3 rounded-xl bg-foreground px-3 py-2.5 text-center text-[13px] font-semibold text-background">{cta}</div>
    </div>
  );
}

function PeriodPicker({ selected, savings }: { readonly selected: IosConfig["defaultBillingPeriod"]; readonly savings: boolean }) {
  const t = useTranslations("opsPaywallLab.ios");
  return (
    <div className="mt-3 flex items-center gap-1 rounded-lg border border-border p-0.5 text-[12px]">
      {(["yearly", "monthly"] as const).map((period) => (
        <span key={period} className={`flex-1 rounded-md px-2 py-1 text-center ${period === selected ? "bg-foreground text-background" : "text-muted"}`}>
          {t(period)}
          {period === "yearly" && savings ? <span className="ml-1 text-[10px]">· {t("yearlySavings")}</span> : null}
        </span>
      ))}
    </div>
  );
}

function IosLayout({
  config,
  plans,
  highlighted,
}: {
  readonly config: IosConfig;
  readonly plans: readonly { readonly id: "pro" | "max"; readonly name: string }[];
  readonly highlighted: "pro" | "max" | null;
}) {
  const t = useTranslations("opsPaywallLab.ios");
  const freeName = useTranslations("pricing")("free.name");
  if (config.layout === "focus") {
    const focus = plans.find((plan) => plan.id === highlighted) ?? plans[0]!;
    return (
      <div className="mt-3 space-y-2">
        <IosPlanRow name={focus.name} recommended large />
        <p className="text-center text-[12px] text-muted underline">{t("seeAllPlans")}</p>
      </div>
    );
  }
  if (config.layout === "comparison") {
    return (
      <div className="mt-3 space-y-1.5">
        <div className="grid grid-cols-3 gap-1 rounded-lg border border-border p-2 text-[11px] text-muted">
          <span>{freeName}</span>
          {plans.map((plan) => <span key={plan.id} className="text-foreground">{plan.name}</span>)}
        </div>
        {plans.map((plan) => <IosPlanRow key={plan.id} name={plan.name} recommended={plan.id === highlighted} />)}
      </div>
    );
  }
  return (
    <div className="mt-3 space-y-1.5">
      {plans.map((plan) => <IosPlanRow key={plan.id} name={plan.name} recommended={plan.id === highlighted} />)}
    </div>
  );
}

function IosPlanRow({ name, recommended, large = false }: { readonly name: string; readonly recommended: boolean; readonly large?: boolean }) {
  const t = useTranslations("opsPaywallLab.ios");
  return (
    <div className={`rounded-xl border px-3 ${large ? "py-4" : "py-2.5"} ${recommended ? "border-foreground" : "border-border"}`}>
      <div className="flex items-center justify-between text-[13px]">
        <span className="font-semibold">{name}</span>
        {recommended ? <Pill>{t("recommended")}</Pill> : null}
      </div>
      <p className="mt-0.5 text-[11px] text-muted">{t("appStorePrice")}</p>
    </div>
  );
}

function Pill({ children }: { readonly children: ReactNode }) {
  return <span className="rounded-full border border-foreground px-1.5 text-[10px] font-medium">{children}</span>;
}
