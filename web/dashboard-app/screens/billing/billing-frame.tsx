"use client";

import type { ErrorComponentProps } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { RouteSectionError } from "@/dashboard-app/components/route-section-error";
import { SettingsPageHeader } from "@/dashboard-app/components/settings-ui";

/** Plan & billing frame inside the Settings hub: rendered while billing loads and when it fails, too. */
export function BillingPageFrame({ children }: { readonly children: ReactNode }) {
  const t = useTranslations("dashboard.billing");
  return (
    <div className="min-w-0">
      <SettingsPageHeader title={t("title")} description={t("description")} />
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
