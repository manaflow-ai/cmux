"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import { useLocale } from "next-intl";
import { useState, useSyncExternalStore } from "react";
import { DashboardSkeleton } from "./components/dashboard-skeleton";
import { createDashboardRouter } from "./router";

const subscribeNever = () => () => {};

/**
 * The dashboard SPA. Next renders only this component for every
 * `/dashboard/*` URL; TanStack Router owns routing and TanStack Query owns
 * data. It renders client-side only because the router uses browser history.
 */
export function DashboardApp() {
  const isClient = useSyncExternalStore(subscribeNever, () => true, () => false);
  if (!isClient) return <DashboardSkeleton />;
  return <DashboardClient />;
}

function DashboardClient() {
  const locale = useLocale();
  const [queryClient] = useState(() => new QueryClient({
    defaultOptions: { queries: { staleTime: 30_000, refetchOnWindowFocus: true } },
  }));
  const [router] = useState(() =>
    createDashboardRouter({ queryClient, locale, pathname: window.location.pathname })
  );
  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  );
}
