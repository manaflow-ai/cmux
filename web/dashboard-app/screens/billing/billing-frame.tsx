"use client";

import type { ErrorComponentProps } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { RouteSectionError } from "@/dashboard-app/components/route-section-error";
import { AccountPlanBadge } from "./account-plan-badge";

/** Billing page frame and header: rendered while billing loads and when it fails, too. */
export function BillingPageFrame({ children }: { readonly children: ReactNode }) {
  const t = useTranslations("dashboard.billing");
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
      {children}
    </div>
  );
}

/** The route's error inside its own frame, naming what failed. */
export function BillingRouteError(props: ErrorComponentProps) {
  const t = useTranslations("dashboard.billing");
  return (
    <BillingPageFrame>
      <RouteSectionError {...props} section={t("title")} />
    </BillingPageFrame>
  );
}
