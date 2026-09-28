"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { Link, useRouter } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import type { ReactNode } from "react";
import { InlineError } from "@/dashboard-app/components/settings-ui/feedback";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { type TeamCatalogEntry, teamCatalogQuery } from "@/dashboard-app/queries/teams";
import { PlanBadge, RoleBadge, TeamAvatar } from "./team-ui";

/** Real teams only; the synthetic personal entry is the user's own account. */
export function listedTeams(teams: readonly TeamCatalogEntry[]): TeamCatalogEntry[] {
  return teams
    .filter((team) => !team.personal)
    .sort((a, b) => a.name.localeCompare(b.name));
}

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

/** `/dashboard/teams`. The route loader prefetches the catalog. */
export function TeamsPage() {
  return (
    <TeamsPageFrame namespace="dashboard.teams.list">
      <TeamsList />
    </TeamsPageFrame>
  );
}

/** Route error for `/dashboard/teams`: the catalog request failed. */
export function TeamsPageError() {
  const t = useTranslations("dashboard.teams.list");
  const router = useRouter();
  return (
    <TeamsPageFrame namespace="dashboard.teams.list">
      <div className="flex flex-wrap items-center justify-between gap-2 border border-border p-3">
        <InlineError message={t("loadError")} />
        <button type="button" className={settingsButtonClass("secondary", "sm")} onClick={() => void router.invalidate()}>
          {t("retry")}
        </button>
      </div>
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
        <div className="border border-border p-4">
          <div className="text-sm font-medium">{t("emptyTitle")}</div>
          <p className="mt-1 text-xs text-muted">{t("emptyBody")}</p>
        </div>
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
                  {typeof team.memberCount === "number" ? (
                    <span className="block text-xs text-muted">{t("members", { count: team.memberCount })}</span>
                  ) : null}
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
