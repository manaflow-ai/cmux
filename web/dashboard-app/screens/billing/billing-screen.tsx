"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useLocale, useTranslations } from "next-intl";

import { CHECKOUT_SOURCE_DASHBOARD_BILLING } from "@/services/analytics/checkoutAttribution";
import {
  MAX_CHECKOUT_URL,
  GO_CHECKOUT_URL,
  PRO_CHECKOUT_URL,
  withCheckoutSource,
  withCheckoutInterval,
} from "@/app/lib/billing";
import {
  FeatureList,
  PlanCard,
  visibleProFeatures,
} from "@/app/components/pricing-shared";
import {
  PricingCheckoutButton,
  PricingView,
} from "@/app/components/pricing-checkout";
import {
  MAX_PRICING_USD,
  GO_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
} from "@/services/billing/plans";
import type {
  PersonalBillingJson,
  PersonalSubscriptionJson,
} from "@/services/billing/dashboardBilling";
import type { BillingTeamSummary } from "@/services/billing/teamBillingView";
import { localeHref } from "../../lib/locale-href";
import { sessionQuery } from "../../lib/session";
import { dashboardBillingQuery } from "../../queries/billing";
import { AccountPlanBadge } from "./account-plan-badge";
import { formatBillingDate, personalPriceCopy } from "./billing-format";
import { TeamBillingPanel } from "./team-billing-panel";

type Translator = ReturnType<typeof useTranslations>;

const BUTTON_CLASS =
  "mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background";

export type BillingScreenSearch = {
  readonly team?: string;
  readonly billing?: string;
  readonly welcome?: string;
};

/** `/dashboard/billing`: the selected scope's plan, then every scope. */
export function BillingScreen({ search }: { search: BillingScreenSearch }) {
  const t = useTranslations("dashboard.billing");
  const { data } = useSuspenseQuery(dashboardBillingQuery(search.team));
  const banner = billingBanner(search.billing);

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
        <div className="mt-2">
          <AccountPlanBadge />
        </div>
      </div>

      {banner ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          {t(`banners.${banner}`)}
        </div>
      ) : null}

      {data.personal ? (
        <PersonalBilling t={t} data={data.personal} />
      ) : data.team ? (
        <TeamBillingPanel view={data.team} welcome={search.welcome === "team"} />
      ) : null}

      <BillingTeamList
        t={t}
        teams={data.teams}
        selectedTeamId={data.selectedTeamId}
      />
    </div>
  );
}

/** The personal entry: Pro/Max, user-scoped. Team billing lives on each team. */
function PersonalBilling({ t, data }: { t: Translator; data: PersonalBillingJson }) {
  const { planStatus: status, subscription } = data;
  // Use the resolver's authoritative recoverability state for the personal
  // billing action. A customer-only or terminally canceled row must show the
  // Upgrade flow; only a portal-recoverable subscription shows Manage billing.
  const canManagePersonalBilling = status.billingManagement === "stripe";
  const isFreePlan = !status.isPro && !canManagePersonalBilling;

  return (
    <>
      {subscription?.status === "past_due" ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          <span>{t("banners.pastDue")}</span>{" "}
          {/* The portal route creates a session and needs a full document navigation. */}
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
          <a href="/api/billing/portal" className="underline">
            {t("actions.manageBilling")}
          </a>
        </div>
      ) : null}

      <PersonalPlan t={t} data={data} isFreePlan={isFreePlan} canManageBilling={canManagePersonalBilling} />

      <MaxUpsell isFreePlan={isFreePlan} planId={status.planId} canManageBilling={canManagePersonalBilling} t={t} />
    </>
  );
}

function PersonalPlan({ t, data, isFreePlan, canManageBilling }: {
  t: Translator;
  data: PersonalBillingJson;
  isFreePlan: boolean;
  canManageBilling: boolean;
}) {
  if (isFreePlan) {
    return <FreePlanUpsell t={t} goPlanEnabled={data.goPlanEnabled} vaultEnabled={data.vaultEnabled} />;
  }
  if (!data.planStatus.isPro) return <FreePlan t={t} showBillingPortal={canManageBilling} />;
  if (data.subscription) {
    return <StripePlan t={t} subscription={data.subscription} canManageBilling={canManageBilling} />;
  }
  // Only a paid operator grant (pro, team, founders) is shown as granted Pro;
  // a "free" or unknown cmuxVmPlan value is not an entitlement.
  if (data.hasPaidManualGrant) return <GrantedPlan t={t} />;
  return <FreePlan t={t} showBillingPortal={canManageBilling} />;
}

/**
 * Every billing scope the user can open, each linking to its view here. The
 * personal entry (the user's own id) is always first.
 */
function BillingTeamList({ t, teams, selectedTeamId }: {
  t: Translator;
  teams: readonly BillingTeamSummary[];
  selectedTeamId: string;
}) {
  // The shell loaded the session before this route, so this reads the cache.
  const { data: session } = useSuspenseQuery(sessionQuery);
  if (teams.length === 0) return null;
  const personal: BillingTeamSummary = {
    id: session.user.id,
    displayName: null,
    personal: true,
    planId: null,
  };
  return (
    <section className="mt-3 border border-border p-3">
      <h2 className="text-sm font-medium">{t("teamList.heading")}</h2>
      <ul className="mt-2 divide-y divide-border">
        {[personal, ...teams].map((team) => (
          <li key={team.id} className="flex items-center justify-between gap-3 py-1.5">
            <Link
              to="/dashboard/billing"
              search={{ team: team.id }}
              className="min-w-0 truncate underline-offset-2 hover:underline"
              aria-current={team.id === selectedTeamId ? "page" : undefined}
            >
              {team.personal ? t("teamList.personal") : team.displayName ?? t("team.fallbackName")}
            </Link>
            {team.personal ? null : (
              <span className="shrink-0 border border-border px-1.5 py-0.5 text-xs text-muted">
                {t(`teamList.planBadges.${planBadgeKey(team.planId)}`)}
              </span>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

function planBadgeKey(planId: string | null): "free" | "team" | "pro" | "max" | "founders" {
  if (planId === "team" || planId === "pro" || planId === "max" || planId === "founders") return planId;
  return "free";
}

function MaxUpsell({ isFreePlan, planId, canManageBilling, t }: {
  isFreePlan: boolean;
  planId: string;
  canManageBilling: boolean;
  t: Translator;
}) {
  const pricingT = useTranslations("pricing");
  if (isFreePlan || !canManageBilling || !["go", "pro"].includes(planId)) return null;
  return (
    <section className="mt-3 border border-border p-3">
      <h2 className="text-sm font-medium">{pricingT("max.name")}</h2>
      <p className="mt-2 text-muted">{t("max.upsell")}</p>
      <a className="mt-3 inline-block underline" href={withCheckoutSource(planId !== "free" ? "/api/billing/portal?flow=switch_plan&plan=max" : MAX_CHECKOUT_URL, CHECKOUT_SOURCE_DASHBOARD_BILLING)}>{pricingT("max.cta")}</a>
    </section>
  );
}

function FreePlan({
  t,
  showBillingPortal = false,
}: {
  t: Translator;
  showBillingPortal?: boolean;
}) {
  const locale = useLocale();
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("free.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("free.body")}</p>
      {showBillingPortal ? (
        // The portal route creates a Stripe session and needs a full document
        // navigation rather than a client transition.
        // eslint-disable-next-line @next/next/no-html-link-for-pages
        <a href="/api/billing/portal" className={BUTTON_CLASS}>
          {t("actions.manageBilling")}
        </a>
      ) : (
        <a href={localeHref(locale, "/pricing")} className={BUTTON_CLASS}>
          {t("actions.viewPricing")}
        </a>
      )}
    </section>
  );
}

// Pro granted by an operator (`cmuxVmPlan`), with no Stripe subscription to
// manage. Shown so a granted account never reads as Free with an upgrade CTA.
function GrantedPlan({ t }: { t: Translator }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("pro.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("pro.grantedBody")}</p>
    </section>
  );
}

function FreePlanUpsell({
  t,
  goPlanEnabled,
  vaultEnabled,
}: {
  t: Translator;
  goPlanEnabled: boolean;
  vaultEnabled: boolean;
}) {
  const pricingT = useTranslations("pricing");
  const proFeatures = visibleProFeatures({
    base: pricingT.raw("pro.features") as string[],
    vault: pricingT.raw("pro.vaultFeatures") as string[],
    hostedNetworking: pricingT.raw("pro.hostedNetworkingFeatures") as string[],
    visibility: {
      vault: vaultEnabled,
      hostedNetworking: false,
    },
  });
  const maxFeatures = pricingT.raw("max.features") as string[];
  const goFeatures = pricingT.raw("go.features") as string[];
  const teamFeatures = pricingT.raw("team.features") as string[];
  const proCheckoutURL = withCheckoutSource(PRO_CHECKOUT_URL, CHECKOUT_SOURCE_DASHBOARD_BILLING);
  // Max is monthly only: one checkout link, no interval parameter.
  const maxCheckoutHref = withCheckoutSource(MAX_CHECKOUT_URL, CHECKOUT_SOURCE_DASHBOARD_BILLING);
  const goCheckoutHref = withCheckoutSource(GO_CHECKOUT_URL, CHECKOUT_SOURCE_DASHBOARD_BILLING);
  const proCheckoutHref = withCheckoutInterval(proCheckoutURL, "month");

  return (
    <PricingView surface="dashboard_billing">
      <div className="space-y-3">
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("free.name")}</h2>
          <p className="mt-2 max-w-2xl text-muted">{t("free.body")}</p>
        </section>

        <section>
          <div className="mb-2">
            <h2 className="text-sm font-medium">{t("free.upsellTitle")}</h2>
            <p className="mt-1 max-w-2xl text-muted">{t("free.upsellBody")}</p>
          </div>
          <div className={`grid gap-3 md:grid-cols-2 ${goPlanEnabled ? "lg:grid-cols-4" : "lg:grid-cols-3"}`}>
            {goPlanEnabled ? <PlanCard
              name={pricingT("go.name")}
              price={`$${GO_PRICING_USD.month.billedAmount}`}
              period={pricingT("perMonth")}
            >
              <PricingCheckoutButton href={goCheckoutHref} location="dashboard_billing" plan="go">
                {pricingT("go.cta")}
              </PricingCheckoutButton>
              <p className="mt-5 text-sm font-medium">{pricingT("go.featuresLead")}</p>
              <FeatureList items={goFeatures} />
            </PlanCard> : null}

            <PlanCard
              name={pricingT("pro.name")}
              price={`$${PRO_PRICING_USD.month.billedAmount}`}
              period={pricingT("perMonth")}
            >
              <PricingCheckoutButton
                href={proCheckoutHref}
                location="dashboard_billing"
              >
                {pricingT("pro.cta")}
              </PricingCheckoutButton>
              <p className="mt-5 text-sm font-medium">{pricingT("pro.featuresLead")}</p>
              <FeatureList items={proFeatures} />
            </PlanCard>

            <PlanCard
              name={pricingT("max.name")}
              price={`$${MAX_PRICING_USD.month.billedAmount}`}
              period={pricingT("perMonth")}
            >
              <PricingCheckoutButton
                href={maxCheckoutHref}
                location="dashboard_billing"
                plan="max"
              >
                {pricingT("max.cta")}
              </PricingCheckoutButton>
              <p className="mt-5 text-sm font-medium">{pricingT("max.featuresLead")}</p>
              <FeatureList items={maxFeatures} />
            </PlanCard>

            <PlanCard
              name={pricingT("team.name")}
              price={`$${TEAM_PRICING_USD.month.billedAmount}`}
              period={pricingT("perUserMonth")}
            >
              {/* Personal accounts buy Pro/Max; Team is bought on a real team. */}
              <Link
                to="/dashboard/teams/new"
                className="mt-4 block border border-border bg-background px-3 py-2 text-center text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
              >
                {t("team.createCta")}
              </Link>
              <p className="mt-5 text-sm font-medium">{pricingT("team.featuresLead")}</p>
              <FeatureList items={teamFeatures} />
            </PlanCard>
          </div>
        </section>

        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("free.testflightTitle")}</h2>
          <p className="mt-2 max-w-2xl text-muted">{t("free.testflightBody")}</p>
          <Link to="/dashboard/testflight" className={BUTTON_CLASS}>
            {t("free.testflightCta")}
          </Link>
        </section>
      </div>
    </PricingView>
  );
}

function StripePlan({
  t,
  subscription,
  canManageBilling,
}: {
  t: Translator;
  subscription: PersonalSubscriptionJson;
  canManageBilling: boolean;
}) {
  const locale = useLocale();
  const plan = subscription.plan === "max" ? "max" : subscription.plan === "go" ? "go" : "pro";
  const price = personalPriceCopy(t, subscription.price, plan);
  const periodDate = formatBillingDate(subscription.currentPeriodEnd, locale) ?? t("dates.unknown");

  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t(`${plan}.name`)}</h2>
      <p className="mt-2 max-w-2xl text-muted">
        {subscription.cancelAtPeriodEnd
          ? t(`${plan}.pendingBody`, { date: periodDate })
          : t(`${plan}.activeBody`, { date: periodDate })}
      </p>

      <div className="mt-4 grid border border-border sm:grid-cols-2">
        <BillingMetric
          label={subscription.cancelAtPeriodEnd ? t("details.endsOn") : t("details.renewsOn")}
          value={periodDate}
        />
        {price ? <BillingMetric label={t("details.price")} value={price} /> : null}
      </div>

      <div className="mt-4 flex flex-wrap items-start gap-2">
        {subscription.cancelAtPeriodEnd ? (
          <form method="post" action="/api/billing/subscription">
            <input type="hidden" name="action" value="resume" />
            <button
              type="submit"
              className="border border-border bg-foreground px-3 py-1.5 text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
            >
              {t("actions.resume")}
            </button>
          </form>
        ) : (
          <details className="border border-border px-3 py-1.5">
            <summary className="cursor-pointer text-foreground">{t("actions.cancelSummary")}</summary>
            <form method="post" action="/api/billing/subscription" className="mt-3 max-w-md">
              <input type="hidden" name="action" value="cancel" />
              <p className="text-muted">{t("cancel.body", { date: periodDate })}</p>
              <label className="mt-3 flex items-start gap-2 text-muted">
                <input
                  required
                  type="checkbox"
                  name="confirm"
                  value="yes"
                  className="mt-0.5"
                />
                <span>{t("cancel.checkbox")}</span>
              </label>
              <button
                type="submit"
                className="mt-3 border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
              >
                {t("actions.confirmCancel")}
              </button>
            </form>
          </details>
        )}

        {canManageBilling ? (
          // This API route creates a Stripe portal session and must perform a
          // full document navigation rather than a client transition.
          // eslint-disable-next-line @next/next/no-html-link-for-pages
          <a
            href="/api/billing/portal"
            className="border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
          >
            {t("actions.manageBilling")}
          </a>
        ) : null}
      </div>
    </section>
  );
}

function BillingMetric({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-border p-3 sm:border-b-0 sm:border-r">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
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
