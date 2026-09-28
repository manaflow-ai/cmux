import { and, desc, eq, inArray, sql } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { CHECKOUT_SOURCE_DASHBOARD_BILLING } from "@/services/analytics/checkoutAttribution";
import {
  MAX_CHECKOUT_URL,
  GO_CHECKOUT_URL,
  PRO_CHECKOUT_URL,
  withCheckoutSource,
  withCheckoutInterval,
} from "@/app/lib/billing";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  FeatureList,
  PlanCard,
  visibleProFeatures,
} from "@/app/components/pricing-shared";
import {
  PricingCheckoutButton,
  PricingView,
} from "@/app/components/pricing-checkout";
import { cloudDb } from "@/db/client";
import { stripeSubscriptions } from "@/db/schema";
import { Link } from "@/i18n/navigation";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PERSONAL_PLAN_IDS,
  isPaidPlanId,
  manualVmPlanOverride,
  resolveProPlanStatus,
} from "@/services/billing/pro";
import {
  listBillingTeams,
  loadTeamBillingView,
  selectedBillingTeamId,
  type BillingTeamSummary,
} from "@/services/billing/teamBillingView";
import { formatUsd, subscriptionPriceFromRaw } from "@/services/billing/subscriptionPrice";
import { billingTeamFromUnknown } from "@/services/billing/teamResolution";
import {
  MAX_PRICING_USD,
  GO_PRICING_USD,
  PRO_PRICING_USD,
  TEAM_PRICING_USD,
} from "@/services/billing/plans";
import { isVaultEnabled } from "@/services/vault/config";
import { isGoPlanEnabled } from "@/services/billing/goPlanFlag";
import { AccountPlanBadge } from "../components/account-plan-badge";
import { TeamBillingPanel } from "./team-billing-panel";


type SearchParams = {
  billing?: string | string[];
  interval?: string | string[];
  team?: string | string[];
  welcome?: string | string[];
};

type Translator = Awaited<ReturnType<typeof getTranslations>>;

type StripeSubscriptionRow = {
  id: string;
  plan?: string;
  status: string;
  priceId: string | null;
  seats: number | null;
  currentPeriodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
  raw: Record<string, unknown> | null;
};

export default async function DashboardBillingPage({
  params,
  searchParams,
}: {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const [{ locale }, query] = await Promise.all([
    params,
    searchParams ?? Promise.resolve(undefined),
  ]);

  if (!isStackConfigured()) {
    redirect("/");
  }
  const user = await getStackServerApp().getUser({ or: "return-null" });
  if (!user) {
    redirect(vaultSignInHref(localizedVaultPath(locale, "/dashboard/billing")));
  }

  const [t, teams] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.billing" }),
    listBillingTeams(user),
  ]);
  const selectedTeamId = selectedBillingTeamId({
    userId: user.id,
    teamIds: teams.map((team) => team.id),
    stackSelectedTeamId: billingTeamFromUnknown(user.selectedTeam)?.id ?? null,
    requestedTeamId: firstBillingParam(query?.team) ?? null,
  });
  const banner = billingBanner(firstBillingParam(query?.billing));
  const isPersonal = selectedTeamId === user.id;

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

      {isPersonal ? (
        <PersonalBilling locale={locale} t={t} data={await loadPersonalBilling(locale, user)} />
      ) : (
        <TeamBillingPanel
          locale={locale}
          t={t}
          view={await loadTeamBillingView(user, selectedTeamId)}
          welcome={firstBillingParam(query?.welcome) === "team"}
        />
      )}

      <BillingTeamList
        t={t}
        personal={{ id: user.id, displayName: null, personal: true, planId: null }}
        teams={teams}
        selectedTeamId={selectedTeamId}
      />
    </div>
  );
}

type PersonalBillingUser = Parameters<typeof resolveProPlanStatus>[0] & {
  readonly id: string;
  readonly clientReadOnlyMetadata?: unknown;
};

async function loadPersonalBilling(locale: string, user: PersonalBillingUser) {
  const [pricingT, status, subscription, goPlanEnabled] = await Promise.all([
    getTranslations({ locale, namespace: "pricing" }),
    resolveProPlanStatus(user),
    latestActiveStripeSubscription(user.id),
    isGoPlanEnabled(user.id),
  ]);
  return { pricingT, status, subscription, goPlanEnabled, metadata: user.clientReadOnlyMetadata };
}

/** The personal entry: Pro/Max, user-scoped. Team billing lives on each team. */
function PersonalBilling({ locale, t, data }: {
  locale: string;
  t: Translator;
  data: Awaited<ReturnType<typeof loadPersonalBilling>>;
}) {
  const { pricingT, status, subscription, goPlanEnabled } = data;
  // Use the resolver's authoritative recoverability state for the personal
  // billing action. A customer-only or terminally canceled row must show the
  // Upgrade flow; only a portal-recoverable subscription shows Manage billing.
  const canManagePersonalBilling = status.billingManagement === "stripe";
  const isFreePlan = !status.isPro && !canManagePersonalBilling;
  // Only a paid operator grant (pro, team, founders) is shown as granted Pro;
  // a "free" or unknown cmuxVmPlan value is not an entitlement.
  const hasPaidManualGrant = isPaidPlanId(manualVmPlanOverride(data.metadata));
  const personalPaymentPastDue = subscription?.status === "past_due";

  return (
    <>
      {personalPaymentPastDue ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          <span>{t("banners.pastDue")}</span>{" "}
          {/* The portal route creates a session and needs a full document navigation. */}
          {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
          <a href="/api/billing/portal" className="underline">
            {t("actions.manageBilling")}
          </a>
        </div>
      ) : null}

      {isFreePlan ? (
        <FreePlanUpsell t={t} pricingT={pricingT} goPlanEnabled={goPlanEnabled} />
      ) : !status.isPro ? (
        <FreePlan t={t} showBillingPortal={canManagePersonalBilling} />
      ) : subscription ? (
        <StripePlan
          t={t}
          locale={locale}
          subscription={subscription}
          canManageBilling={canManagePersonalBilling}
        />
      ) : hasPaidManualGrant ? (
        <GrantedPlan t={t} />
      ) : (
        <FreePlan t={t} showBillingPortal={canManagePersonalBilling} />
      )}

      <MaxUpsell isFreePlan={isFreePlan} planId={status.planId} canManageBilling={canManagePersonalBilling} t={t} pricingT={pricingT} />
    </>
  );
}

/** Every billing scope the user can open, each linking to its view here. */
function BillingTeamList({ t, personal, teams, selectedTeamId }: {
  t: Translator;
  personal: BillingTeamSummary;
  teams: readonly BillingTeamSummary[];
  selectedTeamId: string;
}) {
  if (teams.length === 0) return null;
  return (
    <section className="mt-3 border border-border p-3">
      <h2 className="text-sm font-medium">{t("teamList.heading")}</h2>
      <ul className="mt-2 divide-y divide-border">
        {[personal, ...teams].map((team) => (
          <li key={team.id} className="flex items-center justify-between gap-3 py-1.5">
            <Link
              href={`/dashboard/billing?team=${encodeURIComponent(team.id)}`}
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

function MaxUpsell({ isFreePlan, planId, canManageBilling, t, pricingT }: {
  isFreePlan: boolean; planId: string;
  canManageBilling: boolean;
  t: Awaited<ReturnType<typeof getTranslations>>;
  pricingT: Awaited<ReturnType<typeof getTranslations>>;
}) {
  if (isFreePlan || !canManageBilling || !["go", "pro"].includes(planId)) return null;
  return (
        <section className="mt-3 border border-border p-3">
          <h2 className="text-sm font-medium">{pricingT("max.name")}</h2>
          <p className="mt-2 text-muted">{t("max.upsell")}</p>
          <a className="mt-3 inline-block underline" href={withCheckoutSource(planId !== "free" ? "/api/billing/portal?flow=switch_plan&plan=max" : MAX_CHECKOUT_URL, CHECKOUT_SOURCE_DASHBOARD_BILLING)}>{pricingT("max.cta")}</a>
        </section>
  );
}

async function latestActiveStripeSubscription(stackUserId: string): Promise<StripeSubscriptionRow | null> {
  const rows = await cloudDb()
    .select({
      id: stripeSubscriptions.id,
      plan: stripeSubscriptions.plan,
      status: stripeSubscriptions.status,
      priceId: stripeSubscriptions.priceId,
      seats: stripeSubscriptions.seats,
      currentPeriodEnd: stripeSubscriptions.currentPeriodEnd,
      cancelAtPeriodEnd: stripeSubscriptions.cancelAtPeriodEnd,
      raw: stripeSubscriptions.raw,
    })
    .from(stripeSubscriptions)
    .where(
      and(
        eq(stripeSubscriptions.stackUserId, stackUserId),
        eq(stripeSubscriptions.scope, "user"),
        inArray(stripeSubscriptions.plan, PERSONAL_PLAN_IDS),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(sql`${stripeSubscriptions.plan} = 'max'`), desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

function FreePlan({
  t,
  showBillingPortal = false,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  showBillingPortal?: boolean;
}) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("free.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("free.body")}</p>
      {showBillingPortal ? (
        // The portal route creates a Stripe session and needs a full document
        // navigation rather than a Next.js client transition.
        // eslint-disable-next-line @next/next/no-html-link-for-pages
        <a
          href="/api/billing/portal"
          className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
        >
          {t("actions.manageBilling")}
        </a>
      ) : (
        <Link
          href="/pricing"
          className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
        >
          {t("actions.viewPricing")}
        </Link>
      )}
    </section>
  );
}

// Pro granted by an operator (`cmuxVmPlan`), with no Stripe subscription to
// manage. Shown so a granted account never reads as Free with an upgrade CTA.
function GrantedPlan({ t }: { t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("pro.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("pro.grantedBody")}</p>
    </section>
  );
}

function FreePlanUpsell({
  t,
  pricingT,
  goPlanEnabled,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  pricingT: Awaited<ReturnType<typeof getTranslations>>;
  goPlanEnabled: boolean;
}) {
  const proFeatures = visibleProFeatures({
    base: pricingT.raw("pro.features") as string[],
    vault: pricingT.raw("pro.vaultFeatures") as string[],
    hostedNetworking: pricingT.raw("pro.hostedNetworkingFeatures") as string[],
    visibility: {
      vault: isVaultEnabled(),
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
                href="/dashboard/teams/new"
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
          <Link
            href="/dashboard/testflight"
            className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
          >
            {t("free.testflightCta")}
          </Link>
        </section>
      </div>
    </PricingView>
  );
}

function StripePlan({
  t,
  locale,
  subscription,
  canManageBilling,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  locale: string;
  subscription: StripeSubscriptionRow;
  canManageBilling: boolean;
}) {
  const plan = subscription.plan === "max" ? "max" : subscription.plan === "go" ? "go" : "pro";
  const price = priceCopy(subscription, t, plan);
  const periodDate = subscription.currentPeriodEnd
    ? formatBillingDate(subscription.currentPeriodEnd, locale)
    : t("dates.unknown");

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
          // full document navigation rather than a Next.js client transition.
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

/**
 * What this subscription actually charges, read from its Stripe price. Amounts
 * are immutable per Price, so grandfathered rows ($30/mo, $240/yr, $288/yr,
 * and the Stack-era prices with no lookup key) render their own figure without
 * a per-key copy table that has to grow on every price change.
 */
function priceCopy(
  subscription: StripeSubscriptionRow,
  t: Translator,
  plan: "go" | "pro" | "max",
): string | null {
  const price = subscriptionPriceFromRaw(subscription.raw);
  if (!price) return null;
  if (price.interval === "month") {
    return t(`${plan}.monthlyPrice`, { amount: formatUsd(price.amountUsd) });
  }
  return t(plan === "pro" ? "pro.annualPrice" : `${plan}.monthlyPrice`, {
    monthly: formatUsd(price.amountUsd / 12),
  });
}

function formatBillingDate(date: Date, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(date);
}

function firstBillingParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}
