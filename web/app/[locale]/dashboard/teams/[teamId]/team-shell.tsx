"use client";

import { useStackApp } from "@hexclave/next";
import { useTranslations } from "next-intl";
import { createContext, Suspense, useContext } from "react";
import { Link, usePathname } from "@/i18n/navigation";
import { InlineError } from "../../components/settings-ui/feedback";
import { settingsButtonClass } from "../../components/settings-ui/styles";
import { DashboardSectionSkeleton } from "../../components/dashboard-skeleton";
import { type TeamDetail, TeamApiError, useTeamDetail } from "../team-api";
import { PlanBadge, RoleBadge, TeamAvatar } from "../team-ui";

const TeamDetailContext = createContext<TeamDetail | null>(null);

/** The loaded team for pages under `/dashboard/teams/[teamId]`. */
export function useTeamContext(): TeamDetail {
  const detail = useContext(TeamDetailContext);
  if (!detail) throw new Error("useTeamContext must be used inside TeamShell");
  return detail;
}

export type TeamTab = "general" | "members" | "apiKeys" | "billing";

export function teamTabHref(teamId: string, tab: TeamTab): string {
  const base = `/dashboard/teams/${encodeURIComponent(teamId)}`;
  switch (tab) {
    case "general":
      return base;
    case "members":
      return `${base}/members`;
    case "apiKeys":
      return `${base}/api-keys`;
    case "billing":
      return `${base}/billing`;
  }
}

export function activeTeamTab(pathname: string, teamId: string): TeamTab {
  const base = teamTabHref(teamId, "general");
  const rest = pathname.startsWith(base) ? pathname.slice(base.length) : "";
  if (rest.startsWith("/members")) return "members";
  if (rest.startsWith("/api-keys")) return "apiKeys";
  if (rest.startsWith("/billing")) return "billing";
  return "general";
}

/** A 403 or 404 from the detail route means the viewer is not a member. */
export function isNotMemberError(error: unknown): boolean {
  return error instanceof TeamApiError && (error.status === 403 || error.status === 404);
}

export function TeamShell({ teamId, children }: { readonly teamId: string; readonly children: React.ReactNode }) {
  const detail = useTeamDetail(teamId);

  if (detail.isPending) {
    return (
      <div className="mx-auto w-full max-w-5xl px-3 py-4">
        <DashboardSectionSkeleton variant="rows" />
      </div>
    );
  }
  if (detail.isError || !detail.data) {
    return (
      <div className="mx-auto w-full max-w-5xl px-3 py-4">
        {isNotMemberError(detail.error) ? (
          <TeamNotFound />
        ) : (
          <TeamLoadError onRetry={() => void detail.refetch()} />
        )}
      </div>
    );
  }

  return (
    <TeamDetailContext.Provider value={detail.data}>
      <div className="mx-auto w-full max-w-5xl px-3 py-4">
        <TeamHeader detail={detail.data} />
        {children}
      </div>
    </TeamDetailContext.Provider>
  );
}

export function TeamNotFound() {
  const t = useTranslations("dashboard.teams.shell");
  return (
    <section data-testid="team-not-found" className="max-w-xl border border-border p-4">
      <h1 className="text-sm font-medium">{t("notFoundTitle")}</h1>
      <p className="mt-2 text-sm text-muted">{t("notFoundBody")}</p>
      <Link href="/dashboard/teams" className={`${settingsButtonClass("primary")} mt-4`}>
        {t("backToTeams")}
      </Link>
    </section>
  );
}

function TeamLoadError({ onRetry }: { readonly onRetry: () => void }) {
  const t = useTranslations("dashboard.teams.shell");
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border border-border p-3">
      <InlineError message={t("loadError")} />
      <button type="button" className={settingsButtonClass("secondary", "sm")} onClick={onRetry}>
        {t("retry")}
      </button>
    </div>
  );
}

function TeamHeader({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.shell");
  const pathname = usePathname();
  const active = activeTeamTab(pathname, detail.team.id);
  const tabs: TeamTab[] = ["general", "members"];

  return (
    <div className="mb-4 border-b border-border">
      <div className="flex items-center gap-3 pb-3">
        <TeamAvatar name={detail.team.displayName} imageUrl={detail.team.profileImageUrl} size={36} />
        <div className="min-w-0 flex-1">
          <div className="flex min-w-0 items-center gap-2">
            <h1 className="truncate text-sm font-medium">{detail.team.displayName}</h1>
            <PlanBadge planId={detail.billing.planId} />
            <RoleBadge role={detail.viewer.role} />
          </div>
          <Link href="/dashboard/teams" className="text-xs text-muted hover:text-foreground">
            {t("allTeams")}
          </Link>
        </div>
      </div>
      <nav aria-label={t("tabsLabel")} className="-mb-px flex gap-1 overflow-x-auto">
        {tabs.map((tab) => (
          <TabLink key={tab} teamId={detail.team.id} tab={tab} active={active === tab} />
        ))}
        {detail.viewer.permissions.manageApiKeys ? (
          // Project config comes from a suspending Stack hook; the tab appears once it resolves.
          <Suspense fallback={null}>
            <ApiKeysTab teamId={detail.team.id} active={active === "apiKeys"} />
          </Suspense>
        ) : null}
        <TabLink teamId={detail.team.id} tab="billing" active={active === "billing"} />
      </nav>
    </div>
  );
}

function ApiKeysTab({ teamId, active }: { readonly teamId: string; readonly active: boolean }) {
  const project = useStackApp().useProject();
  if (!project.config.allowTeamApiKeys) return null;
  return <TabLink teamId={teamId} tab="apiKeys" active={active} />;
}

function TabLink({ teamId, tab, active }: { readonly teamId: string; readonly tab: TeamTab; readonly active: boolean }) {
  const t = useTranslations("dashboard.teams.shell.tabs");
  return (
    <Link
      href={teamTabHref(teamId, tab)}
      aria-current={active ? "page" : undefined}
      className={`whitespace-nowrap border-b-2 px-2.5 py-1.5 text-sm focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground ${
        active ? "border-foreground font-medium text-foreground" : "border-transparent text-muted hover:text-foreground"
      }`}
    >
      {t(tab)}
    </Link>
  );
}
