"use client";

import { useQuery } from "@tanstack/react-query";
import { useTranslations } from "next-intl";

import { orpc } from "@/orpc/query";

export function AccountPlanBadge() {
  const t = useTranslations("dashboard.billing.plan");
  const { data, isPending, isError } = useQuery(orpc.account.me.queryOptions());

  // A 401/500/network failure leaves isPending false with data undefined.
  // Don't render then: a fallback "Free" would present a backend failure as an
  // authoritative downgrade. The page's server-rendered plan sections remain.
  if (isError || (!isPending && !data)) {
    return null;
  }

  const label = isPending
    ? t("loading")
    : data?.isPro
      ? t("pro")
      : t("free");

  return (
    <div className="flex items-center gap-2 text-sm text-neutral-500">
      <span>{t("heading")}</span>
      <span className="rounded-md border border-neutral-300 px-2 py-0.5 font-medium text-neutral-800 dark:border-neutral-700 dark:text-neutral-100">
        {label}
      </span>
    </div>
  );
}
