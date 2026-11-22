"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { EmptyState } from "@/dashboard-app/components/page-states";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { type TeamCatalogEntry, teamCatalogQuery } from "@/dashboard-app/queries/teams";
import { TeamsPageFrame } from "./teams-frame";
import { PlanBadge, RoleBadge, TeamAvatar } from "./team-ui";

/** Real teams only; the synthetic personal entry is the user's own account. */
export function listedTeams(teams: readonly TeamCatalogEntry[]): TeamCatalogEntry[] {
  return teams
    .filter((team) => !team.personal)
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** `/dashboard/teams`. The route loader prefetches the catalog. */
export function TeamsPage() {
  return (
    <TeamsPageFrame namespace="dashboard.teams.list">
      <TeamsList />
    </TeamsPageFrame>
  );
}

export function TeamsList() {
  const t = useTranslations("dashboard.teams.list");
  const { data: catalog } = useSuspenseQuery(teamCatalogQuery);

  const createButton = (
    <Link to="/dashboard/teams/new" className={settingsButtonClass("primary")}>
      {t("create")}
    </Link>
  );

  const teams = listedTeams(catalog.teams);
  return (
    <div className="grid gap-3">
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono text-[11px] text-muted">{t("count", { count: teams.length })}</span>
        {createButton}
      </div>
      {teams.length === 0 ? (
        <EmptyState title={t("emptyTitle")} body={t("emptyBody")} />
      ) : (
        <ul className="divide-y divide-border border border-border">
          {teams.map((team) => (
            <li key={team.id}>
              <Link
                to="/dashboard/teams/$teamId"
                params={{ teamId: team.id }}
                className="flex items-center gap-3 px-3 py-2.5 hover:bg-code-bg focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
              >
                <TeamAvatar name={team.name} imageUrl={null} size={28} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-medium">{team.name}</span>
                </span>
                {team.role ? <RoleBadge role={team.role} /> : null}
                <PlanBadge planId={team.planId} />
                {catalog.selectedTeamId === team.id ? (
                  <span className="hidden text-[11px] text-muted sm:inline">{t("selected")}</span>
                ) : null}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
