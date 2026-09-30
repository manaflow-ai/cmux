"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";

import { PricingView } from "@/app/components/pricing-checkout";
import type { PersonalBillingJson } from "@/services/billing/dashboardBilling";
import { localeHref } from "../../lib/locale-href";
import { dashboardBillingQuery } from "../../queries/billing";
import { BillingPageFrame } from "./billing-frame";
import { personalPriceCopy } from "./billing-format";
import { personalPlanCards } from "./plan-model";
import { PlanPicker } from "./plan-picker";
import { PlanWelcome, welcomePlan } from "./plan-welcome";
import { TeamBillingPanel } from "./team-billing-panel";

export type BillingScreenSearch = {
  readonly team?: string;
  readonly billing?: string;
  readonly welcome?: string;
};

/**
 * `/dashboard/billing`, Plan & billing in the Settings hub: the personal
 * plan picker. `?team=` (old links) shows that team's panel instead; teams
 * otherwise use their own Billing tab.
 */
export function BillingScreen({ search }: { search: BillingScreenSearch }) {
  const t = useTranslations("dashboard.billing");
  const { data } = useSuspenseQuery(dashboardBillingQuery(search.team));
  const banner = billingBanner(search.billing);
  const welcome = welcomePlan(search.welcome);

  return (
    <BillingPageFrame>
      {banner ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          {t(`banners.${banner}`)}
        </div>
      ) : null}
      {welcome && data.personal ? <PlanWelcome plan={welcome} /> : null}
      {data.personal ? (
        <PersonalBilling data={data.personal} />
      ) : data.team ? (
        <TeamBillingPanel view={data.team} welcome={search.welcome === "team"} />
      ) : null}
    </BillingPageFrame>
  );
}

function PersonalBilling({ data }: { data: PersonalBillingJson }) {
  const t = useTranslations("dashboard.billing");
  const locale = useLocale();
  const { planStatus: status, subscription } = data;
  const cards = personalPlanCards({
    planId: status.planId,
    isPro: status.isPro,
    subscription: subscription ? { plan: subscription.plan, cancelAtPeriodEnd: subscription.cancelAtPeriodEnd } : null,
    goPlanEnabled: data.goPlanEnabled,
  });
  const picker = (
    <PlanPicker
      cards={cards}
      scope={{ kind: "personal", returnTo: localeHref(locale, "/dashboard/billing") }}
      periodEnd={subscription?.currentPeriodEnd ?? null}
      canManagePayment={status.billingManagement === "stripe"}
      // A plan granted without a subscription charges nothing, so it shows no price.
      currentPrice={subscription ? personalPriceCopy(t, subscription.price, subscriptionPlan(subscription.plan)) : status.isPro ? null : undefined}
    />
  );
  return (
    <>
      {subscription?.status === "past_due" ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          <span>{t("banners.pastDue")}</span>{" "}
          {/* The portal route creates a Stripe session: a full document navigation. */}
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
          <a href="/api/billing/portal" className="underline">{t("picker.paymentMethod")}</a>
        </div>
      ) : null}
      {/* A Free account is a pricing view for analytics, as before. */}
      {cards.find((card) => card.current)?.id === "free" ? <PricingView surface="dashboard_billing">{picker}</PricingView> : picker}
    </>
  );
}

function subscriptionPlan(plan: string | null): "go" | "pro" | "max" {
  return plan === "max" ? "max" : plan === "go" ? "go" : "pro";
}

const BILLING_BANNERS = [
  "cancelled",
  "resumed",
  "nosub",
  "error",
  "team_admin_required",
  "team_not_found",
  "authorization_unavailable",
  "personal_team_not_upgradable_to_team",
] as const;

function billingBanner(value: string | undefined): (typeof BILLING_BANNERS)[number] | null {
  return (BILLING_BANNERS as readonly string[]).includes(value ?? "")
    ? value as (typeof BILLING_BANNERS)[number]
    : null;
}
