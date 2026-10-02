"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";

import type { ReadyTeamBillingViewJson, TeamBillingViewJson } from "@/services/billing/dashboardBilling";
import { teamPortalHref } from "./checkout-links";
import { teamPlanCards } from "./plan-model";
import { PlanPicker } from "./plan-picker";

export { teamCheckoutHref, teamPortalHref } from "./checkout-links";

/**
 * The billing panel for one real team (`/dashboard/teams/$teamId/billing`):
 * notices, seats, then the plan picker. Renders nothing for the personal
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
      <PlanPicker
        cards={teamPlanCards({ canManageBilling: view.canManageBilling, granted: view.granted, subscription: view.subscription })}
        scope={{ kind: "team", teamId: view.team.id }}
        periodEnd={view.subscription?.endsAt ?? view.subscription?.currentPeriodEnd ?? null}
        canManagePayment={view.canManageBilling && view.billingManagement === "stripe"}
        currentPrice={view.subscription ? view.subscription.price : view.granted ? null : undefined}
      />
    </div>
  );
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

