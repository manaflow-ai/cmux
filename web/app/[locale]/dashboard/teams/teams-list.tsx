"use client";

import { useTranslations } from "next-intl";
import { Link } from "@/i18n/navigation";
import { InlineError } from "../components/settings-ui/feedback";
import { settingsButtonClass } from "../components/settings-ui/styles";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { type TeamCatalogEntry, useTeamCatalog } from "./team-api";
import { PlanBadge, RoleBadge, TeamAvatar } from "./team-ui";

/** Real teams only; the synthetic personal entry is the user's own account. */
export function listedTeams(teams: readonly TeamCatalogEntry[]): TeamCatalogEntry[] {
  return teams
    .filter((team) => !team.personal)
    .sort((a, b) => a.name.localeCompare(b.name));
}

export function TeamsList() {
  const t = useTranslations("dashboard.teams.list");
  const catalog = useTeamCatalog();

  const createButton = (
    <Link href="/dashboard/teams/new" className={settingsButtonClass("primary")}>
      {t("create")}
    </Link>
  );

  if (catalog.isPending) return <DashboardSectionSkeleton variant="rows" />;
  if (catalog.isError || !catalog.data) {
    return (
      <div className="flex flex-wrap items-center justify-between gap-2 border border-border p-3">
        <InlineError message={t("loadError")} />
        <button type="button" className={settingsButtonClass("secondary", "sm")} onClick={() => void catalog.refetch()}>
          {t("retry")}
        </button>
      </div>
    );
  }

  const teams = listedTeams(catalog.data.teams);
  return (
    <div className="grid gap-3">
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono text-[11px] text-muted">{t("count", { count: teams.length })}</span>
        {createButton}
      </div>
      {teams.length === 0 ? (
        <div className="border border-border p-4">
          <div className="text-sm font-medium">{t("emptyTitle")}</div>
          <p className="mt-1 text-xs text-muted">{t("emptyBody")}</p>
        </div>
      ) : (
        <ul className="divide-y divide-border border border-border">
          {teams.map((team) => (
            <li key={team.id}>
              <Link
                href={`/dashboard/teams/${encodeURIComponent(team.id)}`}
                className="flex items-center gap-3 px-3 py-2.5 hover:bg-code-bg focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
              >
                <TeamAvatar name={team.name} imageUrl={null} size={28} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-medium">{team.name}</span>
                  {typeof team.memberCount === "number" ? (
                    <span className="block text-xs text-muted">{t("members", { count: team.memberCount })}</span>
                  ) : null}
                </span>
                {team.role ? <RoleBadge role={team.role} /> : null}
                <PlanBadge planId={team.planId} />
                {catalog.data.selectedTeamId === team.id ? (
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
