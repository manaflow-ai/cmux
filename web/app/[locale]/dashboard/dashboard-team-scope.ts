"use client";

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useRef } from "react";
import { useSearchParams } from "next/navigation";
import { usePathname, useRouter } from "@/i18n/navigation";
import {
  clearCoderouterOrganizationScope,
  coderouterOrganizationFromCookieHeader,
  persistCoderouterOrganizationScope,
} from "@/services/coderouter/organizationScope";

export type DashboardTeamCatalog = {
  readonly selectedTeamId: string | null;
  readonly teams: readonly DashboardCatalogTeam[];
};

export type DashboardCatalogTeam = {
  readonly id: string;
  readonly name: string;
  readonly personal: boolean;
  readonly permissions: {
    readonly use: boolean;
    readonly manageAccounts: boolean;
  };
};

export type DashboardTeamScope =
  | { readonly status: "loading" }
  | { readonly status: "unavailable" }
  | {
    readonly status: "ready";
    readonly teams: readonly DashboardCatalogTeam[];
    readonly selected: DashboardCatalogTeam;
    readonly switchTeam: (team: DashboardCatalogTeam) => Promise<void>;
  };

const CATALOG_TIMEOUT_MS = 10_000;

type ConfirmedTeamSwitchState = {
  readonly catalog: DashboardTeamCatalog;
  readonly cookieScope: string | null;
  readonly search: string;
};

/**
 * The dashboard-wide team scope. Stack Auth owns the selected team on the
 * server, so switching here changes what every dashboard surface shows
 * without a page-level picker. The legacy cookie is mirrored for older pages.
 */
export function useDashboardTeamScope(userId: string | null): DashboardTeamScope {
  const {replace, refresh} = useRouter();
  const pathname = usePathname();
  // Dashboard shells mount this hook behind the app's client boundary.
  // oxlint-disable-next-line react-doctor/nextjs-no-use-search-params-without-suspense
  const searchParams = useSearchParams();
  const queryClient = useQueryClient();
  const activeSwitchId = useRef(0);
  const nextSwitchId = useRef(0);
  const pendingSwitches = useRef(0);
  const confirmedSwitchState = useRef<ConfirmedTeamSwitchState | null>(null);
  const switchPersistenceTail = useRef<Promise<void>>(Promise.resolve());
  const queryKey = ["dashboard-team-catalog", userId] as const;
  const { data, isPending } = useQuery({
    queryKey,
    queryFn: ({ signal }) => loadTeamCatalog(signal),
    enabled: userId !== null,
    staleTime: 0,
    refetchOnWindowFocus: "always",
    refetchOnReconnect: "always",
  });

  if (userId === null) return { status: "unavailable" };
  if (isPending) return { status: "loading" };
  if (!data) return { status: "unavailable" };
  const teams = permittedTeams(data);
  if (teams.length === 0) return { status: "unavailable" };
  const selected = selectedTeam(teams, data.selectedTeamId, searchParams.get("team"));

  const switchTeam = async (team: DashboardCatalogTeam) => {
    const currentCatalog = queryClient.getQueryData<DashboardTeamCatalog>(queryKey) ?? data;
    if (
      (pendingSwitches.current === 0 && team.id === selected.id)
      || (pendingSwitches.current > 0 && currentCatalog.selectedTeamId === team.id)
    ) {
      return;
    }

    nextSwitchId.current += 1;
    const operationId = nextSwitchId.current;
    activeSwitchId.current = operationId;

    if (pendingSwitches.current === 0) {
      confirmedSwitchState.current = {
        catalog: currentCatalog,
        cookieScope: coderouterOrganizationFromCookieHeader(
          typeof document === "undefined" ? null : document.cookie,
          userId,
        ),
        search: searchParams.toString(),
      };
    }
    pendingSwitches.current += 1;

    const optimisticSearch = new URLSearchParams(searchParams.toString());
    queryClient.setQueryData<DashboardTeamCatalog>(
      queryKey,
      (current) => current ? { ...current, selectedTeamId: team.id } : current,
    );
    persistCoderouterOrganizationScope(userId, team.id);
    optimisticSearch.set("team", team.id);
    replace(pathWithSearch(pathname, optimisticSearch));

    const persistRequest = async () => {
      const cancellation = new AbortController();
      const timeout = setTimeout(
        () => cancellation.abort(new Error("Team switch timed out")),
        CATALOG_TIMEOUT_MS,
      );
      try {
        const response = await fetch("/api/subrouter/teams", {
          method: "PATCH",
          headers: { "content-type": "application/json", accept: "application/json" },
          body: JSON.stringify({ teamId: team.id }),
          signal: cancellation.signal,
        });
        if (!response.ok) throw new Error("Could not switch dashboard team");
      } finally {
        clearTimeout(timeout);
      }

      const confirmed = confirmedSwitchState.current;
      if (confirmed === null) {
        throw new Error("Dashboard team switch confirmation state was lost");
      }
      const confirmedSearch = new URLSearchParams(confirmed.search);
      confirmedSearch.delete("team");
      const nextConfirmed: ConfirmedTeamSwitchState = {
        catalog: { ...confirmed.catalog, selectedTeamId: team.id },
        cookieScope: team.id,
        search: confirmedSearch.toString(),
      };
      confirmedSwitchState.current = nextConfirmed;
      return nextConfirmed;
    };
    const persist = pendingSwitches.current === 1
      ? persistRequest()
      : switchPersistenceTail.current.then(persistRequest);
    switchPersistenceTail.current = persist.then(
      () => undefined,
      () => undefined,
    );

    const finish = () => {
      pendingSwitches.current -= 1;
      if (pendingSwitches.current === 0) {
        confirmedSwitchState.current = null;
      }
    };

    let confirmed: ConfirmedTeamSwitchState;
    try {
      confirmed = await persist;
    } catch (error) {
      if (activeSwitchId.current === operationId) {
        const rollback = confirmedSwitchState.current;
        if (rollback !== null) {
          queryClient.setQueryData(queryKey, rollback.catalog);
          if (rollback.cookieScope === null) {
            clearCoderouterOrganizationScope();
          } else {
            persistCoderouterOrganizationScope(userId, rollback.cookieScope);
          }
          replace(
            pathWithSearch(pathname, new URLSearchParams(rollback.search)),
          );
        }
        activeSwitchId.current = 0;
      }
      finish();
      throw error;
    }

    if (activeSwitchId.current === operationId) {
      queryClient.setQueryData(queryKey, confirmed.catalog);
      persistCoderouterOrganizationScope(userId, confirmed.cookieScope ?? team.id);
      replace(
        pathWithSearch(pathname, new URLSearchParams(confirmed.search)),
      );
      activeSwitchId.current = 0;
      refresh();
    }
    finish();
  };

  return { status: "ready", teams, selected, switchTeam };
}

function pathWithSearch(pathname: string, searchParams: URLSearchParams): string {
  const query = searchParams.toString();
  return query ? `${pathname}?${query}` : pathname;
}

/** Teams the dashboard can show: route users and account-only managers. */
export function permittedTeams(catalog: DashboardTeamCatalog): readonly DashboardCatalogTeam[] {
  return catalog.teams.filter(
    (team) => team.permissions.use || team.permissions.manageAccounts,
  );
}

/**
 * Mirrors the server: an explicit `?team=` deep link wins, then the persisted
 * scope the catalog already resolved, then the personal team, then the first.
 */
export function selectedTeam(
  teams: readonly DashboardCatalogTeam[],
  catalogSelectedId: string | null,
  requestedId: string | null,
): DashboardCatalogTeam {
  const requested = requestedId?.trim();
  const byRequest = requested ? teams.find((team) => team.id === requested) : undefined;
  if (byRequest) return byRequest;
  const byCatalog = catalogSelectedId
    ? teams.find((team) => team.id === catalogSelectedId)
    : undefined;
  if (byCatalog) return byCatalog;
  return teams.find((team) => team.personal) ?? teams[0];
}

async function loadTeamCatalog(cancellationSignal: AbortSignal): Promise<DashboardTeamCatalog> {
  const response = await fetch("/api/subrouter/teams", {
    headers: { accept: "application/json" },
    signal: AbortSignal.any([cancellationSignal, AbortSignal.timeout(CATALOG_TIMEOUT_MS)]),
  });
  if (!response.ok) throw new Error("Could not load dashboard teams");
  const parsed = parseTeamCatalog(await response.json());
  if (!parsed) throw new Error("Invalid dashboard team response");
  return parsed;
}

export function parseTeamCatalog(value: unknown): DashboardTeamCatalog | null {
  if (!isPlainRecord(value) || !Array.isArray(value.teams)) return null;
  const selectedTeamId = value.selectedTeamId;
  if (selectedTeamId !== null && !validText(selectedTeamId)) return null;
  const teams: DashboardCatalogTeam[] = [];
  const seen = new Set<string>();
  for (const raw of value.teams) {
    if (
      !isPlainRecord(raw) ||
      !validText(raw.id) ||
      !validText(raw.name) ||
      typeof raw.personal !== "boolean" ||
      !isPlainRecord(raw.permissions) ||
      typeof raw.permissions.use !== "boolean" ||
      typeof raw.permissions.manageAccounts !== "boolean" ||
      seen.has(raw.id)
    ) {
      return null;
    }
    seen.add(raw.id);
    teams.push({
      id: raw.id,
      name: raw.name,
      personal: raw.personal,
      permissions: {
        use: raw.permissions.use,
        manageAccounts: raw.permissions.manageAccounts,
      },
    });
  }
  return { selectedTeamId, teams };
}

function validText(value: unknown): value is string {
  return typeof value === "string" &&
    value.length > 0 &&
    value.length <= 200 &&
    value === value.trim();
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
