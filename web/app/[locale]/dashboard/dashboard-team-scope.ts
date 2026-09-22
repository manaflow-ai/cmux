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

/**
 * The dashboard-wide team scope. Stack Auth owns the selected team on the
 * server, so switching here changes what every dashboard surface shows
 * without a page-level picker. The legacy cookie is mirrored for older pages.
 */
export function useDashboardTeamScope(userId: string | null): DashboardTeamScope {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const queryClient = useQueryClient();
  const activeSwitchId = useRef(0);
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
    if (team.id === selected.id) return;
    const operationId = activeSwitchId.current + 1;
    activeSwitchId.current = operationId;
    const previousCatalog = queryClient.getQueryData<DashboardTeamCatalog>(queryKey) ?? data;
    const previousSearch = new URLSearchParams(searchParams.toString());
    const previousCookieScope = typeof document === "undefined"
      ? null
      : coderouterOrganizationFromCookieHeader(document.cookie, userId);
    const optimisticSearch = new URLSearchParams(previousSearch);

    // Update the shared catalog and URL before waiting for Stack Auth. The
    // dashboard pages already treat ?team= as an authorized request scope, so
    // they can start rendering the new team while the persisted selection is
    // being written.
    queryClient.setQueryData<DashboardTeamCatalog>(
      queryKey,
      (current) => current ? { ...current, selectedTeamId: team.id } : current,
    );
    persistCoderouterOrganizationScope(userId, team.id);
    optimisticSearch.set("team", team.id);
    router.replace(pathWithSearch(pathname, optimisticSearch));

    const cancellation = new AbortController();
    const timeout = setTimeout(() => cancellation.abort(new Error("Team switch timed out")), CATALOG_TIMEOUT_MS);
    const rollback = () => {
      if (activeSwitchId.current !== operationId) return;
      queryClient.setQueryData(queryKey, previousCatalog);
      if (previousCookieScope === null) {
        clearCoderouterOrganizationScope();
      } else {
        persistCoderouterOrganizationScope(userId, previousCookieScope);
      }
      router.replace(pathWithSearch(pathname, previousSearch));
      activeSwitchId.current = 0;
    };
    try {
      const response = await fetch("/api/subrouter/teams", {
        method: "PATCH",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({ teamId: team.id }),
        signal: cancellation.signal,
      });
      if (!response.ok) throw new Error("Could not switch dashboard team");
    } catch (error) {
      rollback();
      throw error;
    } finally {
      clearTimeout(timeout);
    }

    // A newer optimistic switch owns the shared catalog, cookie, and URL.
    // Older requests may still settle, but they cannot rewrite newer UI state.
    if (activeSwitchId.current !== operationId) return;
    activeSwitchId.current = 0;
    const next = new URLSearchParams(optimisticSearch);
    next.delete("team");
    router.replace(pathWithSearch(pathname, next));
    router.refresh();
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
