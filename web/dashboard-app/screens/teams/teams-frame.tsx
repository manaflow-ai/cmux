"use client";

import type { ErrorComponentProps } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { DashboardSectionSkeleton } from "@/dashboard-app/components/dashboard-skeleton";
import { RouteSectionError } from "@/dashboard-app/components/route-section-error";
import { SettingsPageHeader } from "@/dashboard-app/components/settings-ui";

/** Page frame shared by `/dashboard/teams` and `/dashboard/teams/new`, inside the Settings hub. */
export function TeamsPageFrame({
  namespace,
  children,
}: {
  readonly namespace: "dashboard.teams.list" | "dashboard.teams.new";
  readonly children: ReactNode;
}) {
  const t = useTranslations(namespace);
  return (
    <div className="min-w-0">
      <SettingsPageHeader title={t("title")} description={t("description")} />
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
    <div className="min-w-0" aria-hidden="true">
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

/** `/dashboard/teams` failed to load the catalog. */
export function TeamsRouteError(props: ErrorComponentProps) {
  const t = useTranslations("dashboard.teams.list");
  return (
    <TeamsPageFrame namespace="dashboard.teams.list">
      <RouteSectionError {...props} section={t("title")} />
    </TeamsPageFrame>
  );
}

/** The team billing tab failed; the team header and tabs stay above it. */
export function TeamBillingRouteError(props: ErrorComponentProps) {
  const t = useTranslations("dashboard.teams.shell.tabs");
  return <RouteSectionError {...props} section={t("billing")} />;
}
