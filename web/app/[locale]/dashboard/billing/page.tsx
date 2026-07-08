import { and, desc, eq, inArray } from "drizzle-orm";
import { getTranslations } from "next-intl/server";
import { redirect } from "next/navigation";

import { PRO_CHECKOUT_URL, TEAM_CHECKOUT_URL } from "@/app/lib/billing";
import { getStackServerApp, isStackConfigured } from "@/app/lib/stack";
import { localizedVaultPath, vaultSignInHref } from "@/app/lib/vault-auth";
import {
  FeatureList,
  PlanCard,
  PrimaryLink,
  visibleProFeatures,
} from "@/app/components/pricing-shared";
import { cloudDb } from "@/db/client";
import { stripeCustomers, stripeSubscriptions } from "@/db/schema";
import { Link } from "@/i18n/navigation";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  PRO_PLAN_ID,
  TEAM_PLAN_ID,
  resolveProPlanStatus,
} from "@/services/billing/pro";

export const dynamic = "force-dynamic";

type SearchParams = {
  billing?: string | string[];
};

type StripeSubscriptionRow = {
  id: string;
  status: string;
  priceId: string | null;
  seats: number | null;
  currentPeriodEnd: Date | null;
  cancelAtPeriodEnd: boolean;
  raw: Record<string, unknown> | null;
};

type BillingTeam = {
  id: string;
  displayName: string | null;
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

  const billingTeamPromise = billingTeamForUser(user);
  const [
    t,
    pricingT,
    status,
    billingTeam,
    subscription,
    hasStripeCustomer,
  ] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.billing" }),
    getTranslations({ locale, namespace: "pricing" }),
    resolveProPlanStatus(user),
    billingTeamPromise,
    latestActiveStripeSubscription(user.id),
    hasCustomerRow(user.id),
  ]);
  const [teamSubscription, hasTeamStripeCustomer] = await Promise.all([
    billingTeam ? latestActiveStripeSubscriptionForTeam(billingTeam.id) : Promise.resolve(null),
    billingTeam ? hasTeamCustomerRow(billingTeam.id) : Promise.resolve(false),
  ]);
  const banner = billingBanner(Array.isArray(query?.billing) ? query?.billing[0] : query?.billing);
  const isFreePlan = !status.isPro && !teamSubscription;

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>

      {banner ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          {t(`banners.${banner}`)}
        </div>
      ) : null}

      {isFreePlan ? (
        <FreePlanUpsell t={t} pricingT={pricingT} />
      ) : !status.isPro ? (
        <FreePlan t={t} />
      ) : subscription ? (
        <StripePlan
          t={t}
          locale={locale}
          subscription={subscription}
          canManageBilling={hasStripeCustomer}
        />
      ) : (
        <LegacyPlan t={t} />
      )}

      {billingTeam && teamSubscription ? (
        <TeamPlan
          t={t}
          locale={locale}
          team={billingTeam}
          subscription={teamSubscription}
          canManageBilling={hasTeamStripeCustomer}
        />
      ) : null}
    </div>
  );
}

async function latestActiveStripeSubscription(stackUserId: string): Promise<StripeSubscriptionRow | null> {
  const rows = await cloudDb()
    .select({
      id: stripeSubscriptions.id,
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
        eq(stripeSubscriptions.plan, PRO_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

async function latestActiveStripeSubscriptionForTeam(stackTeamId: string): Promise<StripeSubscriptionRow | null> {
  const rows = await cloudDb()
    .select({
      id: stripeSubscriptions.id,
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
        eq(stripeSubscriptions.stackTeamId, stackTeamId),
        eq(stripeSubscriptions.scope, "team"),
        eq(stripeSubscriptions.plan, TEAM_PLAN_ID),
        inArray(stripeSubscriptions.status, ACTIVE_STRIPE_PRO_STATUSES),
      ),
    )
    .orderBy(desc(stripeSubscriptions.currentPeriodEnd), desc(stripeSubscriptions.updatedAt))
    .limit(1);
  return rows[0] ?? null;
}

async function hasCustomerRow(stackUserId: string): Promise<boolean> {
  const rows = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackUserId, stackUserId))
    .limit(1);
  return rows.length > 0;
}

async function hasTeamCustomerRow(stackTeamId: string): Promise<boolean> {
  const rows = await cloudDb()
    .select({ id: stripeCustomers.id })
    .from(stripeCustomers)
    .where(eq(stripeCustomers.stackTeamId, stackTeamId))
    .limit(1);
  return rows.length > 0;
}

async function billingTeamForUser(user: unknown): Promise<BillingTeam | null> {
  const stackUser = user as {
    selectedTeam?: unknown;
    listTeams?: () => Promise<readonly unknown[]>;
  };
  const selected = teamFromUnknown(stackUser.selectedTeam);
  if (selected) return selected;
  const teams = typeof stackUser.listTeams === "function"
    ? (await stackUser.listTeams()).map(teamFromUnknown).filter((team): team is BillingTeam => !!team)
    : [];
  return teams.length === 1 ? teams[0] : null;
}

function teamFromUnknown(value: unknown): BillingTeam | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { id?: unknown }).id;
  if (typeof id !== "string" || !id) return null;
  const displayName = (value as { displayName?: unknown }).displayName;
  return {
    id,
    displayName: typeof displayName === "string" && displayName.trim()
      ? displayName
      : null,
  };
}

function FreePlan({ t }: { t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("free.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("free.body")}</p>
      <Link
        href="/pricing"
        className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
      >
        {t("actions.viewPricing")}
      </Link>
    </section>
  );
}

function FreePlanUpsell({
  t,
  pricingT,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  pricingT: Awaited<ReturnType<typeof getTranslations>>;
}) {
  const proFeatures = visibleProFeatures({
    base: pricingT.raw("pro.features") as string[],
    vault: pricingT.raw("pro.vaultFeatures") as string[],
    hostedNetworking: pricingT.raw("pro.hostedNetworkingFeatures") as string[],
  });
  const teamFeatures = pricingT.raw("team.features") as string[];

  return (
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
        <div className="grid gap-3 md:grid-cols-2">
          <PlanCard
            name={pricingT("pro.name")}
            price={pricingT("pro.price")}
            period={pricingT("perMonth")}
          >
            <PrimaryLink href={PRO_CHECKOUT_URL}>{pricingT("pro.cta")}</PrimaryLink>
            <p className="mt-5 text-sm font-medium">{pricingT("pro.featuresLead")}</p>
            <FeatureList items={proFeatures} />
          </PlanCard>

          <PlanCard
            name={pricingT("team.name")}
            price={pricingT("team.price")}
            period={pricingT("perUserMonth")}
          >
            <PrimaryLink href={TEAM_CHECKOUT_URL}>{pricingT("team.cta")}</PrimaryLink>
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
  const price = priceCopy(subscription);
  const periodDate = subscription.currentPeriodEnd
    ? formatBillingDate(subscription.currentPeriodEnd, locale)
    : t("dates.unknown");

  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("pro.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">
        {subscription.cancelAtPeriodEnd
          ? t("pro.pendingBody", { date: periodDate })
          : t("pro.activeBody", { date: periodDate })}
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

function TeamPlan({
  t,
  locale,
  team,
  subscription,
  canManageBilling,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  locale: string;
  team: BillingTeam;
  subscription: StripeSubscriptionRow;
  canManageBilling: boolean;
}) {
  const periodDate = subscription.currentPeriodEnd
    ? formatBillingDate(subscription.currentPeriodEnd, locale)
    : t("dates.unknown");
  const seats = String(subscription.seats ?? 1);

  return (
    <section className="mt-3 border border-border p-3">
      <h2 className="text-sm font-medium">{t("team.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">
        {subscription.cancelAtPeriodEnd
          ? t("team.pendingBody", { date: periodDate, team: team.displayName ?? t("team.fallbackName") })
          : t("team.activeBody", { date: periodDate, team: team.displayName ?? t("team.fallbackName") })}
      </p>

      <div className="mt-4 grid border border-border sm:grid-cols-3">
        <BillingMetric
          label={subscription.cancelAtPeriodEnd ? t("details.endsOn") : t("details.renewsOn")}
          value={periodDate}
        />
        <BillingMetric label={t("details.seats")} value={seats} />
        <BillingMetric label={t("details.price")} value={t("team.price")} />
      </div>

      <div className="mt-4 flex flex-wrap items-start gap-2">
        {subscription.cancelAtPeriodEnd ? (
          <form method="post" action="/api/billing/subscription">
            <input type="hidden" name="scope" value="team" />
            <input type="hidden" name="teamId" value={team.id} />
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
              <input type="hidden" name="scope" value="team" />
              <input type="hidden" name="teamId" value={team.id} />
              <input type="hidden" name="action" value="cancel" />
              <p className="text-muted">{t("cancel.teamBody", { date: periodDate })}</p>
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
          <a
            href="/api/billing/portal?scope=team"
            className="border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
          >
            {t("actions.manageBilling")}
          </a>
        ) : null}
      </div>
    </section>
  );
}

function LegacyPlan({ t }: { t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("pro.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("legacy.body")}</p>
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

function billingBanner(value: string | undefined) {
  return value === "cancelled" || value === "resumed" || value === "nosub" || value === "error"
    ? value
    : null;
}

function priceCopy(subscription: StripeSubscriptionRow): string | null {
  const lookupKey = priceLookupKey(subscription) ?? subscription.priceId;
  if (lookupKey === "cmux-pro-monthly") return "$30/month";
  if (lookupKey === "cmux-pro-yearly") return "$240/year";
  return null;
}

function priceLookupKey(subscription: StripeSubscriptionRow): string | null {
  const raw = subscription.raw;
  const items = raw && typeof raw === "object" ? raw.items : null;
  const data = items && typeof items === "object" && "data" in items
    ? (items as { data?: unknown }).data
    : null;
  const firstItem = Array.isArray(data) ? data[0] : null;
  const price = firstItem && typeof firstItem === "object" && "price" in firstItem
    ? (firstItem as { price?: unknown }).price
    : null;
  const lookupKey = price && typeof price === "object" && "lookup_key" in price
    ? (price as { lookup_key?: unknown }).lookup_key
    : null;
  return typeof lookupKey === "string" ? lookupKey : null;
}

function formatBillingDate(date: Date, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(date);
}
