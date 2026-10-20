import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryHistory, createRootRoute, createRouter, RouterContextProvider } from "@tanstack/react-router";
import type { ReactNode } from "react";

/**
 * Wrap a dashboard component in a loaded memory-history TanStack router at
 * `path` plus a fresh QueryClient, so `Link` renders real hrefs and active
 * state without the SPA route tree. Pass `queryClient` to seed the cache.
 */
export async function withDashboardRouter(
  element: ReactNode,
  path = "/dashboard",
  queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } }),
) {
  const router = createRouter({
    routeTree: createRootRoute(),
    history: createMemoryHistory({ initialEntries: [path] }),
  });
  await router.load();
  return {
    router,
    queryClient,
    element: (
      <QueryClientProvider client={queryClient}>
        <RouterContextProvider router={router as never}>{element}</RouterContextProvider>
      </QueryClientProvider>
    ),
  };
}
