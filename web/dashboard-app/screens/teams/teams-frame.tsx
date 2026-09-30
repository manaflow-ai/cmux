"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";

/** Page frame shared by `/dashboard/teams` and `/dashboard/teams/new`. */
export function TeamsPageFrame({
  namespace,
  children,
}: {
  readonly namespace: "dashboard.teams.list" | "dashboard.teams.new";
  readonly children: ReactNode;
}) {
  const t = useTranslations(namespace);
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {children}
    </div>
  );
}

/**
 * `/dashboard/teams/$teamId` while the team loads: the page column, a header
 * placeholder the size of the team header, and the members layout.
 */
export function TeamShellPending() {
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4" aria-hidden="true">
      <div className="mb-4 border-b border-border">
        <div className="flex items-center gap-3 pb-3">
          <div className="h-9 w-9 animate-pulse bg-code-bg" />
          <div>
            <div className="h-4 w-40 animate-pulse bg-code-bg" />
            <div className="mt-2 h-3 w-16 animate-pulse bg-code-bg" />
          </div>
        </div>
        <div className="flex gap-3 pb-2">
          <div className="h-4 w-14 animate-pulse bg-code-bg" />
          <div className="h-4 w-16 animate-pulse bg-code-bg" />
          <div className="h-4 w-12 animate-pulse bg-code-bg" />
        </div>
      </div>
      <DashboardSectionSkeleton variant="settings" />
    </div>
  );
}
