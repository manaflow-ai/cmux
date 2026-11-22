"use client";

import { useLocale, useTranslations } from "next-intl";
import { type ReactNode, useState } from "react";
import { Badge, InlineError } from "@/dashboard-app/components/settings-ui";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { useResumePlan } from "@/dashboard-app/queries/billing";
import type { SubscriptionPrice } from "@/services/billing/subscriptionPrice";
import { formatBillingDate } from "./billing-format";
import { CancelPlanDialog } from "./cancel-plan-dialog";
import { ChangePlanDialog } from "./change-plan-dialog";
import { personalCheckoutHref, teamCheckoutHref, teamPortalHref } from "./checkout-links";
import { type PlanCard, planCardPrice, sharedUnavailableReason, type SwitchPlanId } from "./plan-model";

/** Personal scope, or the team whose plan this is. */
export type PickerScope = { readonly kind: "personal"; readonly returnTo: string } | { readonly kind: "team"; readonly teamId: string };

/**
 * One card per plan, the current one marked, each with one action: Stripe
 * Checkout from Free, an in-place switch between paid plans, Cancel on the
 * Free card, Resume on a cancelling plan, or why nothing can change.
 */
export function PlanPicker({
  cards,
  scope,
  periodEnd,
  canManagePayment,
  currentPrice,
}: {
  readonly cards: readonly PlanCard[];
  readonly scope: PickerScope;
  /** ISO end of the current paid period, when there is one. */
  readonly periodEnd: string | null;
  /** Shows the payment method and invoice links (Stripe-managed billing). */
  readonly canManagePayment: boolean;
  /**
   * What the current subscription actually charges ("$30/mo" for a
   * grandfathered price), replacing the list price on the current card; null
   * when Stripe sent no usable amount, which shows no amount at all.
   */
  /** The current subscription's own Stripe price; null when granted; undefined for the list price. */
  readonly currentPrice?: SubscriptionPrice | null;
}) {
  const t = useTranslations("dashboard.billing.picker");
  const locale = useLocale();
  const [switchTo, setSwitchTo] = useState<SwitchPlanId | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const resume = useResumePlan();
  const teamId = scope.kind === "team" ? scope.teamId : undefined;
  const periodDate = formatBillingDate(periodEnd, locale);
  const current = cards.find((card) => card.current);
  const paidCurrent = current && current.id !== "free" ? current.id : null;
  const portalHref = teamId ? teamPortalHref(teamId) : "/api/billing/portal";
  const sharedReason = sharedUnavailableReason(cards);

  const action = (card: PlanCard): ReactNode => {
    const name = t(`names.${card.id}`);
    switch (card.action.kind) {
      case "current":
        return periodDate && card.id !== "free" ? <p className="text-xs text-muted">{t("renewsOn", { date: periodDate })}</p> : null;
      case "resume":
        return (
          <div className="space-y-2">
            {periodDate ? <p className="text-xs text-muted">{t("endsOn", { date: periodDate })}</p> : null}
            <button
              type="button"
              disabled={resume.isPending}
              onClick={() => resume.mutate(teamId ? { teamId } : {})}
              className={settingsButtonClass("primary", "sm")}
            >
              {t("resume", { plan: name })}
            </button>
            {resume.isError ? <InlineError message={t("actionError")} /> : null}
          </div>
        );
      case "checkout": {
        const plan = card.action.plan;
        // Checkout is a route handler that redirects to Stripe: a full document navigation.
        const href = plan === "team" ? teamCheckoutHref(teamId ?? "") : personalCheckoutHref(plan, scope.kind === "personal" ? scope.returnTo : "/dashboard/billing");
        return (
          <a href={href} className={settingsButtonClass("primary", "sm")}>
            {t("upgradeTo", { plan: name })}
          </a>
        );
      }
      case "switch": {
        const plan = card.action.plan;
        return (
          <button type="button" onClick={() => setSwitchTo(plan)} className={settingsButtonClass("secondary", "sm")}>
            {t("switchTo", { plan: name })}
          </button>
        );
      }
      case "cancel":
        return (
          <button type="button" onClick={() => setCancelling(true)} className={settingsButtonClass("secondary", "sm")}>
            {t("cancelPlan")}
          </button>
        );
      case "unavailable":
        // A reason every other card shares is said once, under the cards.
        return sharedReason ? null : <p className="text-xs text-muted">{t(`unavailable.${card.action.reason}`)}</p>;
    }
  };

  return (
    <section aria-label={t("heading")} data-testid="plan-picker">
      <div className={`grid gap-3 sm:grid-cols-2 ${cards.length > 3 ? "lg:grid-cols-4" : cards.length === 3 ? "lg:grid-cols-3" : ""}`}>
        {cards.map((card) => (
          <article
            key={card.id}
            data-plan={card.id}
            aria-current={card.current ? "true" : undefined}
            className={`flex flex-col border p-3 ${card.current ? "border-foreground" : "border-border"}`}
          >
            <div className="flex items-center justify-between gap-2">
              <h2 className="text-sm font-medium">{t(`names.${card.id}`)}</h2>
              {card.current ? <Badge>{t("current")}</Badge> : null}
            </div>
            <CardPrice price={planCardPrice(card.id, card.current, currentPrice)} />
            <ul className="mt-3 space-y-1 text-xs text-muted">
              {(t.raw(`features.${card.id}`) as string[]).map((line) => <li key={line}>{line}</li>)}
            </ul>
            <div className="mt-auto pt-4">{action(card)}</div>
          </article>
        ))}
      </div>

      {sharedReason ? <p className="mt-2 text-xs text-muted" data-testid="plan-picker-note">{t(`unavailable.${sharedReason}`)}</p> : null}
      {canManagePayment ? (
        <div className="mt-3 flex flex-wrap gap-2">
          {/* The portal route creates a Stripe session: a full document navigation. */}
          <a href={portalHref} className={settingsButtonClass("secondary", "sm")}>{t("paymentMethod")}</a>
          <a href={portalHref} className={settingsButtonClass("ghost", "sm")}>{t("invoices")}</a>
        </div>
      ) : null}

      <ChangePlanDialog plan={switchTo} onOpenChange={(open) => { if (!open) setSwitchTo(null); }} />
      {paidCurrent ? (
        <CancelPlanDialog open={cancelling} onOpenChange={setCancelling} plan={paidCurrent} endsOn={periodDate} teamId={teamId} />
      ) : null}
    </section>
  );
}

function CardPrice({ price }: { readonly price: ReturnType<typeof planCardPrice> }) {
  const t = useTranslations("dashboard.billing.picker");
  if (!price) return null;
  return (
    <p className="mt-2">
      <span className="text-lg font-medium tabular-nums">{price.amount}</span>{" "}
      <span className="text-xs text-muted">
        {t(price.unit)}
        {price.annual ? `, ${t("billedAnnually")}` : ""}
      </span>
    </p>
  );
}
