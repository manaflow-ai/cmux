"use client";

import { useQuery } from "@tanstack/react-query";
import { useTranslations } from "next-intl";

import { orpc } from "@/orpc/query";
import { SkeletonPill } from "../../components/dashboard-skeleton";

export function AccountPlanBadge() {
  const t = useTranslations("dashboard.billing.plan");
  const { data, isPending, isError } = useQuery(orpc.account.me.queryOptions());

  // A 401/500/network failure leaves isPending false with data undefined.
  // Don't render then: a fallback "Free" would present a backend failure as an
  // authoritative downgrade. The screen's plan sections below still render.
  if (isError || (!isPending && !data)) {
    return null;
  }

  return (
    <div className="flex items-center gap-2 text-xs text-muted">
      <span>{t("heading")}</span>
      {isPending ? (
        <SkeletonPill />
      ) : (
        <span className="border border-border px-1.5 py-0.5 text-[11px] font-medium text-foreground">
          {data?.isPro ? t("pro") : t("free")}
        </span>
      )}
    </div>
  );
}
