"use client";

import { useQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { SkeletonLine } from "@/dashboard-app/components/dashboard-skeleton";
import { ConfirmDialog, InlineError } from "@/dashboard-app/components/settings-ui";
import { dashboardRefusal } from "@/dashboard-app/lib/refusal";
import { planChangePreviewQuery, useChangePlan } from "@/dashboard-app/queries/billing";
import { formatBillingDate } from "./billing-format";
import type { SwitchPlanId } from "./plan-model";

/** A Stripe amount in minor units, in the viewer's locale. */
export function formatMinorAmount(amount: number, currency: string, locale: string): string {
  return new Intl.NumberFormat(locale, { style: "currency", currency: currency.toUpperCase() }).format(amount / 100);
}

/**
 * Switch between paid plans in place. The dialog loads Stripe's preview when
 * it opens, and the change reuses the preview's proration date, so the
 * amount shown is the amount charged.
 */
export function ChangePlanDialog({
  plan,
  onOpenChange,
}: {
  /** The target plan; null closes the dialog. */
  readonly plan: SwitchPlanId | null;
  readonly onOpenChange: (open: boolean) => void;
}) {
  const t = useTranslations("dashboard.billing");
  const locale = useLocale();
  const change = useChangePlan();
  const target = plan ?? "pro";
  const preview = useQuery({ ...planChangePreviewQuery(target), enabled: plan !== null });
  const name = t(`picker.names.${target}`);
  const data = preview.data;
  const money = (amount: number) => formatMinorAmount(amount, data?.currency ?? "usd", locale);
  const date = formatBillingDate(data?.nextRenewalAt ?? null, locale) ?? "";

  return (
    <ConfirmDialog
      open={plan !== null}
      onOpenChange={onOpenChange}
      tone="default"
      title={t("change.title", { plan: name })}
      description={
        data ? (
          <p>
            {data.direction === "upgrade"
              ? t("change.upgradeBody", { plan: name, amount: money(data.amountDueToday), date, price: money(data.nextInvoiceAmount) })
              : t("change.downgradeBody", { plan: name, credit: money(data.credit), date, amount: money(data.nextInvoiceAmount) })}
          </p>
        ) : preview.isError ? (
          <InlineError message={t("change.previewError")} />
        ) : (
          <span aria-hidden="true" className="block space-y-1.5">
            <SkeletonLine className="w-full" />
            <SkeletonLine className="w-4/5" />
          </span>
        )
      }
      confirmLabel={t("change.confirm", { plan: name })}
      dismissLabel={t("change.keep")}
      confirmDisabled={!data}
      describeError={(error) =>
        dashboardRefusal(error)?.reason === "payment_failed" ? t("change.paymentFailed") : t("change.error")}
      onConfirm={async () => {
        if (!data) return;
        await change.mutateAsync({ plan: data.plan, prorationDate: data.prorationDate });
      }}
    />
  );
}
