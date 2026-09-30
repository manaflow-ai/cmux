"use client";

import { useLocale, useTranslations } from "next-intl";

import { CHECKOUT_SOURCE_DASHBOARD_BILLING } from "@/services/analytics/checkoutAttribution";
import {
  TEAM_CHECKOUT_URL,
  withCheckoutInterval,
  withCheckoutSource,
} from "@/app/lib/billing";
import type {
  ReadyTeamBillingViewJson,
  TeamBillingSubscriptionJson,
  TeamBillingViewJson,
} from "@/services/billing/dashboardBilling";
import { formatBillingDate, teamPriceCopy } from "./billing-format";

type Translator = ReturnType<typeof useTranslations>;

const BUTTON_CLASS =
  "inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background";
const PRIMARY_BUTTON_CLASS =
  "inline-block border border-border bg-foreground px-3 py-1.5 text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground";

/** Team checkout for an explicit team; the route re-checks admin. */
export function teamCheckoutHref(teamId: string): string {
  const withTeam = `${TEAM_CHECKOUT_URL}&teamId=${encodeURIComponent(teamId)}`;
  return withCheckoutInterval(withCheckoutSource(withTeam, CHECKOUT_SOURCE_DASHBOARD_BILLING), "month");
}

export function teamPortalHref(teamId: string): string {
  return `/api/billing/portal?scope=team&teamId=${encodeURIComponent(teamId)}`;
}

/**
 * The billing panel for one real team, shared by `/dashboard/billing` and
 * `/dashboard/teams/$teamId/billing`. The caller reads `view` from
 * `teamBillingQuery(teamId)` (or the billing screen's query). Renders nothing
 * for the personal entry; callers show Pro/Max there.
 */
export function TeamBillingPanel({
  view,
  welcome = false,
}: {
  view: TeamBillingViewJson;
  welcome?: boolean;
}) {
  const t = useTranslations("dashboard.billing");
  const locale = useLocale();
  if (view.status === "personal") return null;
  if (view.status !== "ready") {
    return (
      <section className="border border-border p-3">
        <p className="text-muted">
          {view.status === "not_found" ? t("teamPanel.notFound") : t("teamPanel.unavailable")}
        </p>
      </section>
    );
  }
  return (
    <div className="space-y-3">
      {welcome ? <Notice>{t("teamPanel.welcome")}</Notice> : null}
      {view.paymentPastDue && view.canManageBilling ? (
        <Notice>
          <span>{t("banners.pastDue")}</span>{" "}
          <PortalLink teamId={view.team.id} className="underline">{t("actions.manageBilling")}</PortalLink>
        </Notice>
      ) : null}
      {view.subscription ? (
        <ActiveTeamPlan t={t} locale={locale} view={view} subscription={view.subscription} />
      ) : view.granted ? (
        <GrantedTeamPlan t={t} view={view} />
      ) : (
        <FreeTeamPlan t={t} view={view} />
      )}
    </div>
  );
}

function teamName(t: Translator, view: ReadyTeamBillingViewJson): string {
  return view.team.displayName ?? t("team.fallbackName");
}

function Notice({ children }: { children: React.ReactNode }) {
  return <div className="border border-border bg-background p-3 text-sm">{children}</div>;
}

function PortalLink({
  teamId,
  className,
  children,
}: {
  teamId: string;
  className: string;
  children: React.ReactNode;
}) {
  // The portal route creates a Stripe session and needs a full document
  // navigation, so it stays a plain link outside the SPA router.
  return <a href={teamPortalHref(teamId)} className={className}>{children}</a>;
}

function MemberReadOnlyNote({ t }: { t: Translator }) {
  return <p className="mt-3 text-muted">{t("teamPanel.memberReadOnly")}</p>;
}

function FreeTeamPlan({ t, view }: { t: Translator; view: ReadyTeamBillingViewJson }) {
  const team = teamName(t, view);
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("free.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("teamPanel.freeBody", { team })}</p>
      {view.canManageBilling ? (
        <div className="mt-3 flex flex-wrap gap-2">
          {/* Checkout is a route handler that redirects to Stripe. */}
          <a href={teamCheckoutHref(view.team.id)} className={PRIMARY_BUTTON_CLASS}>
            {t("teamPanel.upgradeCta")}
          </a>
          {view.billingManagement === "stripe" ? (
            <PortalLink teamId={view.team.id} className={BUTTON_CLASS}>{t("actions.manageBilling")}</PortalLink>
          ) : null}
        </div>
      ) : (
        <p className="mt-3 text-muted">{t("teamPanel.askAdmin", { team })}</p>
      )}
    </section>
  );
}

function GrantedTeamPlan({ t, view }: { t: Translator; view: ReadyTeamBillingViewJson }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("team.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("teamPanel.grantedBody", { team: teamName(t, view) })}</p>
    </section>
  );
}

function ActiveTeamPlan({
  t,
  locale,
  view,
  subscription,
}: {
  t: Translator;
  locale: string;
  view: ReadyTeamBillingViewJson;
  subscription: TeamBillingSubscriptionJson;
}) {
  const team = teamName(t, view);
  const periodDate = formatBillingDate(subscription.currentPeriodEnd, locale) ?? t("dates.unknown");
  const price = teamPriceCopy(t, subscription.price);
  const seats = view.seats ?? 1;
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("team.name")}</h2>
      <p className="mt-2 max-w-2xl text-muted">
        {subscription.cancelAtPeriodEnd
          ? t("team.pendingBody", { date: periodDate, team })
          : t("team.activeBody", { date: periodDate, team })}
      </p>

      <div className="mt-4 grid border border-border sm:grid-cols-3">
        <Metric
          label={subscription.cancelAtPeriodEnd ? t("details.endsOn") : t("details.renewsOn")}
          value={periodDate}
        />
        <Metric
          label={t("details.seats")}
          value={view.memberCount === null
            ? String(seats)
            : t("teamPanel.seatsUsed", { members: view.memberCount, seats })}
        />
        {price ? <Metric label={t("details.price")} value={price} /> : null}
      </div>

      {view.overSeat && view.canManageBilling ? (
        <p className="mt-3 max-w-2xl text-muted">
          {t("teamPanel.overSeat", { team, members: view.memberCount ?? 0, seats })}{" "}
          <PortalLink teamId={view.team.id} className="underline">{t("teamPanel.addSeats")}</PortalLink>
        </p>
      ) : null}

      {view.canManageBilling ? (
        <TeamSubscriptionActions t={t} teamId={view.team.id} periodDate={periodDate} subscription={subscription} />
      ) : (
        <MemberReadOnlyNote t={t} />
      )}
    </section>
  );
}

function TeamSubscriptionActions({
  t,
  teamId,
  periodDate,
  subscription,
}: {
  t: Translator;
  teamId: string;
  periodDate: string;
  subscription: TeamBillingSubscriptionJson;
}) {
  return (
    <div className="mt-4 flex flex-wrap items-start gap-2">
      {subscription.cancelAtPeriodEnd ? (
        <form method="post" action="/api/billing/subscription">
          <input type="hidden" name="scope" value="team" />
          <input type="hidden" name="teamId" value={teamId} />
          <input type="hidden" name="action" value="resume" />
          <button type="submit" className={PRIMARY_BUTTON_CLASS}>{t("actions.resume")}</button>
        </form>
      ) : (
        <details className="border border-border px-3 py-1.5">
          <summary className="cursor-pointer text-foreground">{t("actions.cancelSummary")}</summary>
          <form method="post" action="/api/billing/subscription" className="mt-3 max-w-md">
            <input type="hidden" name="scope" value="team" />
            <input type="hidden" name="teamId" value={teamId} />
            <input type="hidden" name="action" value="cancel" />
            <p className="text-muted">{t("cancel.teamBody", { date: periodDate })}</p>
            <label className="mt-3 flex items-start gap-2 text-muted">
              <input required type="checkbox" name="confirm" value="yes" className="mt-0.5" />
              <span>{t("cancel.checkbox")}</span>
            </label>
            <button type="submit" className={`mt-3 ${BUTTON_CLASS}`}>{t("actions.confirmCancel")}</button>
          </form>
        </details>
      )}
      <PortalLink teamId={teamId} className={BUTTON_CLASS}>{t("actions.manageBilling")}</PortalLink>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-border p-3 sm:border-b-0 sm:border-r">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
    </div>
  );
}
