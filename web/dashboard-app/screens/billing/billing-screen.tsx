"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";

import { PricingView } from "@/app/components/pricing-checkout";
import type { PersonalBillingJson } from "@/services/billing/dashboardBilling";
import { localeHref } from "../../lib/locale-href";
import { InlineError } from "@/dashboard-app/components/settings-ui";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { dashboardBillingQuery, useResumePlan } from "../../queries/billing";
import { formatBillingDate } from "./billing-format";
import { BillingPageFrame } from "./billing-frame";
import { planStanding } from "./plan-status";
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
  // An App Store subscriber changes or cancels in the App Store; offering
  // Stripe checkout here would bill them twice for one plan. A Stripe
  // subscription that still bills them alongside it keeps its controls, so it
  // can be cancelled or its payment fixed here.
  if (data.planStatus.billingSource === "apple") {
    return (
      <>
        <AppStoreBilling manageUrl={data.planStatus.manageUrl} />
        {data.planStatus.billingManagement === "stripe" ? (
          <div className="mt-3">
            <StripePersonalBilling data={data} />
          </div>
        ) : null}
      </>
    );
  }
  return <StripePersonalBilling data={data} />;
}

function AppStoreBilling({ manageUrl }: { manageUrl: string | null }) {
  const t = useTranslations("dashboard.billing.appStore");
  return (
    <div className="border border-border bg-background p-4 text-sm">
      <p className="font-medium">{t("title")}</p>
      <p className="mt-1 text-muted">{t("body")}</p>
      {manageUrl ? (
        <a href={manageUrl} target="_blank" rel="noopener noreferrer" className="mt-3 inline-block underline">
          {t("manage")}
        </a>
      ) : null}
    </div>
  );
}

function StripePersonalBilling({ data }: { data: PersonalBillingJson }) {
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
      // A cancelled subscription ends at Stripe's `cancel_at`, which can differ from the period end.
      periodEnd={subscription?.endsAt ?? subscription?.currentPeriodEnd ?? null}
      canManagePayment={status.billingManagement === "stripe"}
      resubscribePlan={data.endedSubscription?.plan ?? null}
      // A plan granted without a subscription charges nothing, so it shows no price.
      currentPrice={subscription ? subscription.price : status.isPro ? null : undefined}
    />
  );
  return (
    <>
      <PlanEndingNotice data={data} />
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

/** Cancelled but still paid for, or already ended; nothing while the plan renews. */
function PlanEndingNotice({ data }: { data: PersonalBillingJson }) {
  const { planStatus: status, subscription, endedSubscription } = data;
  const standing = planStanding({
    isPro: subscription !== null,
    cancelScheduled: subscription?.cancelAtPeriodEnd === true,
    endsAt: subscription?.endsAt ?? null,
    paymentPastDue: subscription?.status === "past_due",
  });
  const currentPlan = paidPlan(subscription?.plan ?? status.planId);
  if (standing.kind === "cancelling" && currentPlan) {
    return <CancelledPlanNotice plan={currentPlan} endsAt={standing.endsAt} />;
  }
  if (!subscription && !status.isPro && endedSubscription) {
    return <EndedPlanNotice plan={endedSubscription.plan} endedAt={endedSubscription.endedAt} />;
  }
  return null;
}

function paidPlan(value: string | null): "go" | "pro" | "max" | null {
  return value === "go" || value === "pro" || value === "max" ? value : null;
}

/**
 * A cancelled plan that is still paid for: the exact day it ends (Stripe's
 * date), what Free leaves out, and Resume.
 */
function CancelledPlanNotice({ plan, endsAt }: { plan: "go" | "pro" | "max"; endsAt: string | null }) {
  const t = useTranslations("dashboard.billing");
  const locale = useLocale();
  const resume = useResumePlan();
  const name = t(`picker.names.${plan}`);
  const date = formatBillingDate(endsAt, locale);
  const lose = t.raw(`picker.features.${plan}`) as string[];
  return (
    <div role="status" data-testid="plan-cancelled-notice" className="mb-3 border border-foreground bg-background p-3 text-sm">
      <p className="font-medium">{t("notice.cancelledTitle", { plan: name })}</p>
      <p className="mt-1">
        {date ? t("notice.cancelledBody", { plan: name, date }) : t("notice.cancelledBodyNoDate", { plan: name })}
      </p>
      <ul className="mt-1 list-disc pl-5 text-muted">
        {lose.map((line) => <li key={line}>{line}</li>)}
      </ul>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button
          type="button"
          disabled={resume.isPending}
          onClick={() => resume.mutate({})}
          className={settingsButtonClass("primary", "sm")}
        >
          {t("picker.resume", { plan: name })}
        </button>
        {resume.isError ? <InlineError message={t("cancelDialog.resumeError")} /> : null}
      </div>
    </div>
  );
}

/** A plan that already ended: when, and that the plan's card resubscribes. */
function EndedPlanNotice({ plan, endedAt }: { plan: "go" | "pro" | "max"; endedAt: string | null }) {
  const t = useTranslations("dashboard.billing");
  const locale = useLocale();
  const name = t(`picker.names.${plan}`);
  const date = formatBillingDate(endedAt, locale);
  return (
    <div role="status" data-testid="plan-ended-notice" className="mb-3 border border-border bg-background p-3 text-sm">
      {date ? t("notice.endedBody", { plan: name, date }) : t("notice.endedBodyNoDate", { plan: name })}
    </div>
  );
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
