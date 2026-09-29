import type { QueryClient } from "@tanstack/react-query";
import { createRouter, type RouterHistory } from "@tanstack/react-router";
import { DashboardSkeleton } from "./components/dashboard-skeleton";
import { dashboardBasepath } from "./lib/basepath";
import { dashboardHistory } from "./lib/history";
import { parseFlatSearch, stringifyFlatSearch } from "./lib/search";
import { routeTree } from "./route-tree";
import { DashboardNotFound } from "./shell/dashboard-not-found";
import { DashboardRouteError } from "./shell/dashboard-frame";

export function createDashboardRouter(input: {
  readonly queryClient: QueryClient;
  readonly locale: string;
  readonly pathname: string;
  /** Tests pass a memory history; the app uses the Next-aware browser history. */
  readonly history?: RouterHistory;
}) {
  return createRouter({
    routeTree,
    history: input.history ?? dashboardHistory(),
    basepath: dashboardBasepath(input.pathname),
    context: { queryClient: input.queryClient, locale: input.locale },
    parseSearch: parseFlatSearch,
    stringifySearch: stringifyFlatSearch,
    // Queries own freshness; the router always asks the cache.
    defaultPreload: "intent",
    defaultPreloadStaleTime: 0,
    defaultPendingComponent: () => <DashboardSkeleton />,
    defaultErrorComponent: DashboardRouteError,
    defaultNotFoundComponent: DashboardNotFound,
    scrollRestoration: true,
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof createDashboardRouter>;
  }
}
