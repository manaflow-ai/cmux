import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
} from "@tanstack/react-router";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { parseFlatSearch, stringifyFlatSearch } from "../../dashboard-app/lib/search";

/** A QueryClient for screen tests: no retries, nothing refetches on mount. */
export function createScreenQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity } },
  });
}

/**
 * Renders one dashboard screen inside a memory-history TanStack router at
 * `url`, so typed `Link`s produce real hrefs. Seed `queryClient` with
 * `setQueryData` first; a screen that suspends on an unseeded query renders
 * its Suspense fallback.
 */
export async function renderDashboardScreen(input: {
  readonly url: string;
  readonly queryClient: QueryClient;
  readonly render: () => ReactNode;
}): Promise<string> {
  const pathname = new URL(input.url, "https://cmux.test").pathname;
  const rootRoute = createRootRoute();
  const screenRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: pathname,
    component: () => <>{input.render()}</>,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([screenRoute]),
    history: createMemoryHistory({ initialEntries: [input.url] }),
    parseSearch: parseFlatSearch,
    stringifySearch: stringifyFlatSearch,
  });
  await router.load();
  return renderToStaticMarkup(
    <QueryClientProvider client={input.queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>,
  );
}
