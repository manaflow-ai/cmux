"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useLocation, useRouter } from "@tanstack/react-router";
import { useCallback } from "react";
import { parseFlatSearch } from "./search";

/**
 * The current dashboard URL for code that works with raw query strings
 * (team scope, optimistic URL rollback). Paths exclude the locale basepath.
 */
export function useDashboardUrl() {
  const router = useRouter();
  const queryClient = useQueryClient();
  const location = useLocation();
  const replaceSearch = useCallback((search: URLSearchParams) => {
    void router.navigate({
      to: router.state.location.pathname,
      search: parseFlatSearch(search.toString()),
      replace: true,
    } as never);
  }, [router]);
  // Replaces Next's `router.refresh()`: every dashboard read is a query, so
  // refetching queries and rerunning loaders reloads the visible screen.
  const refresh = useCallback(async () => {
    await Promise.all([queryClient.invalidateQueries(), router.invalidate()]);
  }, [queryClient, router]);
  return {
    pathname: location.pathname,
    searchParams: new URLSearchParams(location.searchStr),
    replaceSearch,
    refresh,
  };
}
