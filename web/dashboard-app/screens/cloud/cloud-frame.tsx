"use client";

import type { ErrorComponentProps } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { RequiresPro } from "@/dashboard-app/components/requires-pro";
import { RouteSectionError } from "@/dashboard-app/components/route-section-error";

/** Page frame and header, shown while the device list loads. */
export function CloudPageFrame({ children }: { readonly children: ReactNode }) {
  const t = useTranslations("dashboard.cloud");
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      <RequiresPro feature="cloud" />
      {children}
    </div>
  );
}

/** The route's error inside its own frame, naming what failed. */
export function CloudRouteError(props: ErrorComponentProps) {
  const t = useTranslations("dashboard.cloud");
  return (
    <CloudPageFrame>
      <RouteSectionError {...props} section={t("title")} />
    </CloudPageFrame>
  );
}
