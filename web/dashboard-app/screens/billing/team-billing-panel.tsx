"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";

import type { ReadyTeamBillingViewJson, TeamBillingViewJson } from "@/services/billing/dashboardBilling";
import type { TeamEnterpriseDeal as EnterpriseDealJson } from "@/services/billing/teamEnterprise";
import { teamPortalHref } from "./checkout-links";
import { teamPlanCards } from "./plan-model";
import { PlanPicker } from "./plan-picker";

export { teamCheckoutHref, teamPortalHref } from "./checkout-links";

/**
 * The billing panel for one real team (`/dashboard/teams/$teamId/billing`):
 * notices, seats, then the plan picker, or the enterprise deal for a team
 * on one. Renders nothing for the personal
 * entry; Plan & billing shows Pro and Max there.
 */
export function TeamBillingPanel({
  view,
  welcome = false,
}: {
  view: TeamBillingViewJson;
  welcome?: boolean;
}) {
  const t = useTranslations("dashboard.billing");
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
          <a href={teamPortalHref(view.team.id)} className="underline">{t("actions.manageBilling")}</a>
        </Notice>
      ) : null}
      {view.subscription ? <TeamSeats view={view} /> : null}
      {view.enterprise ? <EnterprisePlan view={view} deal={view.enterprise} /> : <PlanPicker
        cards={teamPlanCards({ canManageBilling: view.canManageBilling, granted: view.granted, subscription: view.subscription })}
        scope={{ kind: "team", teamId: view.team.id }}
        periodEnd={view.subscription?.currentPeriodEnd ?? null}
        canManagePayment={view.canManageBilling && view.billingManagement === "stripe"}
        currentPrice={view.subscription ? view.subscription.price : view.granted ? null : undefined}
      />}
    </div>
  );
}

/**
 * An enterprise deal arranged with the cmux team: its plan name, the price for
 * team admins, and the Cloud VM limits it gives, in place of the plan picker.
 */
function EnterprisePlan({ view, deal }: { view: ReadyTeamBillingViewJson; deal: EnterpriseDealJson }) {
  const t = useTranslations("dashboard.billing");
  const team = view.team.displayName ?? t("team.fallbackName");
  const gb = (memoryMb: number) => String(Math.round((memoryMb / 1024) * 10) / 10);
  const noLimit = t("teamPanel.enterprise.noLimit");
  return (
    <section className="border border-border" aria-label={deal.label}>
      <div className="flex items-baseline justify-between gap-3 p-3">
        <h2 className="text-sm font-medium">{deal.label}</h2>
        <span className="text-xs text-muted">{t("teamPanel.enterprise.current")}</span>
      </div>
      <p className="border-t border-border p-3 text-xs text-muted">{t("teamPanel.enterprise.body", { team })}</p>
      {view.canManageBilling && view.billingManagement === "stripe" ? (
        <p className="border-t border-border p-3 text-xs">
          <a href={teamPortalHref(view.team.id)} className="underline">{t("actions.manageBilling")}</a>
        </p>
      ) : null}
      <div className="grid grid-cols-2 border-t border-border sm:grid-cols-4">
        {deal.monthlyPriceUsd !== null ? (
          <Metric
            label={t("teamPanel.enterprise.price")}
            value={t("teamPanel.enterprise.perMonth", { amount: formatUsd(deal.monthlyPriceUsd) })}
          />
        ) : null}
        <Metric label={t("teamPanel.enterprise.machines")} value={deal.maxActiveVms === null ? noLimit : String(deal.maxActiveVms)} />
        <Metric
          label={t("teamPanel.enterprise.pool")}
          value={deal.poolVcpus === null || deal.poolMemoryMb === null
            ? noLimit
            : t("teamPanel.enterprise.size", { vcpus: deal.poolVcpus, gb: gb(deal.poolMemoryMb) })}
        />
        <Metric
          label={t("teamPanel.enterprise.largest")}
          value={t("teamPanel.enterprise.size", { vcpus: deal.maxVcpus, gb: gb(deal.maxMemoryMb) })}
        />
      </div>
    </section>
  );
}

function formatUsd(amount: number): string {
  return `$${amount.toLocaleString("en-US", { minimumFractionDigits: Number.isInteger(amount) ? 0 : 2, maximumFractionDigits: 2 })}`;
}

function Notice({ children }: { children: ReactNode }) {
  return <div className="border border-border bg-background p-3 text-sm">{children}</div>;
}

/** Seats in use, and the line for a count the subscription has not caught up with. */
function TeamSeats({ view }: { view: ReadyTeamBillingViewJson }) {
  const t = useTranslations("dashboard.billing");

  const seats = view.seats ?? 1;
  const team = view.team.displayName ?? t("team.fallbackName");
  return (
    <section className="border border-border">
      <Metric
        label={t("details.seats")}
        value={view.memberCount === null ? String(seats) : t("teamPanel.seatsUsed", { members: view.memberCount, seats })}
      />
      {view.overSeat && view.canManageBilling ? (
        <p className="border-t border-border p-3 text-xs text-muted">
          {t("teamPanel.overSeat", { team, members: view.memberCount ?? 0, seats })}
        </p>
      ) : null}
    </section>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="p-3">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
    </div>
  );
}

