"use client";

import { useStackApp } from "@hexclave/next";
import { useSuspenseQuery } from "@tanstack/react-query";
import { type ErrorComponentProps, getRouteApi, Link, type LinkOptions, Outlet } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { createContext, Suspense, useContext } from "react";
import { RouteSectionError } from "@/dashboard-app/components/route-section-error";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { isNotMemberError, type TeamDetail, teamDetailQuery } from "@/dashboard-app/queries/teams";
import { PlanBadge, RoleBadge, TeamAvatar } from "./team-ui";

const teamRouteApi = getRouteApi("/shell/dashboard/teams/$teamId");

const TeamDetailContext = createContext<TeamDetail | null>(null);

/** The loaded team for pages under `/dashboard/teams/$teamId`. */
export function useTeamContext(): TeamDetail {
  const detail = useContext(TeamDetailContext);
  if (!detail) throw new Error("useTeamContext must be used inside TeamShell");
  return detail;
}

export type TeamTab = "general" | "members" | "apiKeys" | "billing";

/** Typed router target of one team tab. */
export function teamTabLink(teamId: string, tab: TeamTab) {
  const params = { teamId };
  switch (tab) {
    case "general":
      return { to: "/dashboard/teams/$teamId", params, activeOptions: { exact: true } } satisfies LinkOptions;
    case "members":
      return { to: "/dashboard/teams/$teamId/members", params } satisfies LinkOptions;
    case "apiKeys":
      return { to: "/dashboard/teams/$teamId/api-keys", params } satisfies LinkOptions;
    case "billing":
      return { to: "/dashboard/teams/$teamId/billing", params } satisfies LinkOptions;
  }
}

/**
 * Layout of `/dashboard/teams/$teamId`. The route loader already fetched the
 * detail, and its error component handles "not a member" and outages.
 */
export function TeamShell() {
  const { teamId } = teamRouteApi.useParams();
  const { data: detail } = useSuspenseQuery(teamDetailQuery(teamId));
  return (
    <TeamDetailContext.Provider value={detail}>
      <div className="mx-auto w-full max-w-5xl px-3 py-4">
        <TeamHeader detail={detail} />
        <Outlet />
      </div>
    </TeamDetailContext.Provider>
  );
}

/** Route error for the team layout: a 403 or 404 means the viewer is not a member. */
export function TeamShellError(props: ErrorComponentProps) {
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      {isNotMemberError(props.error) ? <TeamNotFound /> : <RouteSectionError {...props} />}
    </div>
  );
}

export function TeamNotFound() {
  const t = useTranslations("dashboard.teams.shell");
  return (
    <section data-testid="team-not-found" className="max-w-xl border border-border p-4">
      <h1 className="text-sm font-medium">{t("notFoundTitle")}</h1>
      <p className="mt-2 text-sm text-muted">{t("notFoundBody")}</p>
      <Link to="/dashboard/teams" className={`${settingsButtonClass("primary")} mt-4`}>
        {t("backToTeams")}
      </Link>
    </section>
  );
}

function TeamHeader({ detail }: { readonly detail: TeamDetail }) {
  const t = useTranslations("dashboard.teams.shell");
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
          <Link to="/dashboard/teams" className="text-xs text-muted hover:text-foreground">
            {t("allTeams")}
          </Link>
        </div>
      </div>
      <nav aria-label={t("tabsLabel")} className="-mb-px flex gap-1 overflow-x-auto">
        {tabs.map((tab) => (
          <TabLink key={tab} teamId={detail.team.id} tab={tab} />
        ))}
        {detail.viewer.permissions.manageApiKeys ? (
          // Project config comes from a suspending Stack hook; the tab appears once it resolves.
          <Suspense fallback={null}>
            <ApiKeysTab teamId={detail.team.id} />
          </Suspense>
        ) : null}
        <TabLink teamId={detail.team.id} tab="billing" />
      </nav>
    </div>
  );
}

function ApiKeysTab({ teamId }: { readonly teamId: string }) {
  const project = useStackApp().useProject();
  if (!project.config.allowTeamApiKeys) return null;
  return <TabLink teamId={teamId} tab="apiKeys" />;
}

const TAB_CLASS =
  "whitespace-nowrap border-b-2 px-2.5 py-1.5 text-sm focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground";

/** The router marks the current tab active and sets `aria-current`. */
function TabLink({ teamId, tab }: { readonly teamId: string; readonly tab: TeamTab }) {
  const t = useTranslations("dashboard.teams.shell.tabs");
  return (
    <Link
      {...teamTabLink(teamId, tab)}
      className={TAB_CLASS}
      activeProps={{ className: "border-foreground font-medium text-foreground" }}
      inactiveProps={{ className: "border-transparent text-muted hover:text-foreground" }}
    >
      {t(tab)}
    </Link>
  );
}
