"use client";

import { useTranslations } from "next-intl";
import { Badge } from "@/dashboard-app/components/settings-ui";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import type { NextCloudBillingJson } from "@/services/billing/dashboardBilling";
import { formatUsd } from "@/services/billing/subscriptionPrice";
import { nextCloudCheckoutHref } from "./checkout-links";
import { type NextPlanCard, nextPlanCards } from "./next-plan-model";

/**
 * cmux NEXT Cloud on Plan & billing: the account's NEXT plan and the two
 * plans with their price, included usage and limits. Subscribe and Upgrade
 * go to checkout; a plan whose price is not configured yet is Coming soon.
 */
export function NextCloudPlans({ next, returnTo }: { readonly next: NextCloudBillingJson; readonly returnTo: string }) {
  const t = useTranslations("dashboard.billing.nextCloud");
  const cards = nextPlanCards(next);
  const currentName = next.planId ? t(`names.${next.planId}`) : t("none");

  return (
    <section aria-label={t("heading")} data-testid="next-cloud-plans" className="mt-6">
      <h2 className="text-sm font-medium">{t("heading")}</h2>
      <p className="mt-1 text-xs text-muted" data-testid="next-cloud-current">
        {t("currentPlan", { plan: currentName })}
        {next.source === "grant" ? ` ${t("granted")}` : ""}
      </p>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        {cards.map((card) => (
          <article
            key={card.offer.id}
            data-next-plan={card.offer.id}
            aria-current={card.current ? "true" : undefined}
            className={`flex flex-col border p-3 ${card.current ? "border-foreground" : "border-border"}`}
          >
            <div className="flex items-center justify-between gap-2">
              <h3 className="text-sm font-medium">{t(`names.${card.offer.id}`)}</h3>
              {card.current ? <Badge>{t("current")}</Badge> : null}
            </div>
            <p className="mt-2">
              <span className="text-lg font-medium tabular-nums">{`$${formatUsd(card.offer.priceUsdPerMonth)}`}</span>{" "}
              <span className="text-xs text-muted">{t("perMonth")}</span>
            </p>
            <ul className="mt-3 space-y-1 text-xs text-muted">
              <li>{t("features.includedMinutes", { minutes: card.offer.includedMachineMinutes })}</li>
              <li>{t("features.running", { count: card.offer.maxRunningMachines })}</li>
              <li>{t("features.kept", { count: card.offer.maxKeptMachines })}</li>
              <li>{t("features.snapshots", { count: card.offer.maxSnapshots })}</li>
              <li>{t("features.largest", { vcpus: card.offer.largestMachine.vcpus, memory: card.offer.largestMachine.memoryGib })}</li>
              <li>{t("features.disk", { disk: card.offer.maxDiskGib })}</li>
            </ul>
            <div className="mt-auto pt-4">
              <NextPlanAction card={card} returnTo={returnTo} />
            </div>
          </article>
        ))}
      </div>
      <p className="mt-2 text-xs text-muted">{t("machineMinuteNote")}</p>
      <p className="mt-1 text-xs text-muted">{t("usageNote")}</p>
    </section>
  );
}

function NextPlanAction({ card, returnTo }: { readonly card: NextPlanCard; readonly returnTo: string }) {
  const t = useTranslations("dashboard.billing.nextCloud");
  switch (card.action.kind) {
    case "current":
    case "included":
      return null;
    case "comingSoon":
      return (
        <button type="button" disabled aria-disabled="true" className={settingsButtonClass("secondary", "sm")}>
          {t("comingSoon")}
        </button>
      );
    case "checkout":
      // Checkout is a route handler that redirects to the payment page: a full document navigation.
      return (
        <a href={nextCloudCheckoutHref(card.offer.id, returnTo)} className={settingsButtonClass("primary", "sm")}>
          {t(card.action.label, { plan: t(`names.${card.offer.id}`) })}
        </a>
      );
  }
}
