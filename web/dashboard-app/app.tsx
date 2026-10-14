"use client";

import { type DehydratedState, hydrate, QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import { useLocale } from "next-intl";
import { useState, useSyncExternalStore } from "react";
import { DashboardSkeleton } from "./components/dashboard-skeleton";
import { createDashboardQueryClient, createSignInRedirect } from "./lib/query-client";
import { createDashboardRouter } from "./router";

const subscribeNever = () => () => {};

/**
 * The dashboard SPA. Next renders only this component for every
 * `/dashboard/*` URL; TanStack Router owns routing and TanStack Query owns
 * data. It renders client-side only because the router uses browser history.
 */
export function DashboardApp({ dehydratedState }: { readonly dehydratedState?: DehydratedState }) {
  const isClient = useSyncExternalStore(subscribeNever, () => true, () => false);
  if (!isClient) return <DashboardSkeleton />;
  return <DashboardClient dehydratedState={dehydratedState} />;
}

/** `dehydratedState` is the page's server prefetch of the first route's reads. */
function DashboardClient({ dehydratedState }: { readonly dehydratedState?: DehydratedState }) {
  const locale = useLocale();
  // Hydrate before the router exists, so its first load finds the data.
  const [queryClient] = useState(() => {
    const client = createDashboardQueryClient(createSignInRedirect(locale));
    if (dehydratedState) hydrate(client, dehydratedState);
    return client;
  });
  const [router] = useState(() =>
    createDashboardRouter({ queryClient, locale, pathname: window.location.pathname })
  );
  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  );
}
