// Server only: imported by the dashboard page, never by the SPA.
import { createRouterClient, ORPCError } from "@orpc/server";
import { type DataTag, dehydrate, type DehydratedState, QueryClient, type QueryKey } from "@tanstack/react-query";
import { dashboardRouter } from "@/orpc/server/dashboard/router";
import { sessionQuery } from "./lib/session";
import { dashboardBillingQuery, teamBillingQuery } from "./queries/billing";
import { cloudDevicesQuery } from "./queries/cloud";
import { coderouterOverviewQuery } from "./queries/coderouter";
import {
  settingsApiKeysQuery,
  settingsNotificationsQuery,
  settingsOAuthProvidersQuery,
  settingsOverviewQuery,
  settingsSessionsQuery,
} from "./queries/settings";
import { teamCatalogQuery, teamDetailQuery } from "./queries/teams";
import { testflightQuery } from "./queries/testflight";
import { vaultSessionQuery, vaultSummaryQuery } from "./queries/vault";

type ServerClient = ReturnType<typeof serverClient>;

function serverClient(request: Request) {
  return createRouterClient(dashboardRouter, { context: { request, serverPrefetch: true } });
}

/** One query of the first route: its client key and the in-process call that fills it. */
type Prefetch = (client: ServerClient, queryClient: QueryClient) => Promise<void>;

function query<Output>(
  options: { readonly queryKey: DataTag<QueryKey, Output, unknown> },
  run: (client: ServerClient) => Promise<Output>,
): Prefetch {
  return async (client, queryClient) => {
    queryClient.setQueryData(options.queryKey, await run(client));
  };
}

type Search = Readonly<Record<string, string | undefined>>;

/**
 * The reads each route's loader makes, by public dashboard path (without the
 * locale prefix). Keys come from the same query options the loaders use, so
 * the SPA finds the data in its cache and renders without a request.
 */
function routePrefetches(path: string, search: Search): Prefetch[] {
  const team = search.team?.trim() || undefined;
  const segments = path.split("/").filter(Boolean).slice(1);
  const [section, id, tab] = segments;
  switch (section) {
    case "billing":
      return [query(dashboardBillingQuery(team), (client) => client.account.billing({ team: team ?? null }))];
    case "testflight":
      return [query(testflightQuery, (client) => client.account.testflight())];
    case "coderouter":
      return [query(coderouterOverviewQuery(team), (client) => client.coderouter.overview({ team: team ?? null }))];
    case "cloud":
      return [query(cloudDevicesQuery, (client) => client.cloud.devices())];
    case "teams":
      if (!id) return [query(teamCatalogQuery, (client) => client.teams.catalog())];
      if (id === "new") return [];
      return [
        query(teamDetailQuery(id), (client) => client.teams.detail({ teamId: id })),
        ...(tab === "billing" ? [query(teamBillingQuery(id), (client) => client.teams.billing({ teamId: id }))] : []),
      ];
    case "vault":
      if (!id) return [query(vaultSummaryQuery, (client) => client.vault.summary())];
      if (id === "sessions" && tab) return [query(vaultSessionQuery(tab), (client) => client.vault.session({ id: tab }))];
      return [];
    case "settings":
      return settingsPrefetches(id);
    default:
      return [];
  }
}

function settingsPrefetches(page: string | undefined): Prefetch[] {
  const overview = query(settingsOverviewQuery, (client) => client.settings.overview());
  switch (page) {
    case "auth":
      return [overview, query(settingsOAuthProvidersQuery, (client) => client.settings.oauthProviders())];
    case "notifications":
      return [query(settingsNotificationsQuery, (client) => client.settings.notifications())];
    case "sessions":
      return [query(settingsSessionsQuery, (client) => client.settings.sessions())];
    case "api-keys":
      return [async (client, queryClient) => {
        await overview(client, queryClient);
        if (queryClient.getQueryData(settingsOverviewQuery.queryKey)?.project.allowUserApiKeys) {
          await query(settingsApiKeysQuery, (server) => server.settings.apiKeys())(client, queryClient);
        }
      }];
    case "account":
      return [overview];
    default:
      return [];
  }
}

export type DashboardPrefetch =
  | { readonly kind: "signedOut" }
  | { readonly kind: "ready"; readonly state: DehydratedState };

/**
 * Load the session and the first route's reads on the server, in process.
 * A signed-out session is reported so the page can redirect before any SPA
 * code loads; every other failure is left for the SPA to fetch and render
 * in place, exactly as on a client navigation.
 */
export async function prefetchDashboard(request: Request, path: string, search: Search): Promise<DashboardPrefetch> {
  const client = serverClient(request);
  const queryClient = new QueryClient();
  try {
    await query(sessionQuery, (server) => server.account.session())(client, queryClient);
  } catch (error) {
    if (error instanceof ORPCError && error.status === 401) return { kind: "signedOut" };
    return { kind: "ready", state: dehydrate(queryClient) };
  }
  await Promise.all(routePrefetches(path, search).map((prefetch) => prefetch(client, queryClient).catch(() => undefined)));
  return { kind: "ready", state: dehydrate(queryClient) };
}
