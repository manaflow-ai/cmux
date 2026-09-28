import type { QueryClient } from "@tanstack/react-query";
import { createRootRouteWithContext, createRoute, Outlet } from "@tanstack/react-router";
import { z } from "zod";
import { DashboardSkeleton } from "../components/dashboard-skeleton";
import { sessionQuery } from "../lib/session";
import { DashboardFrame, DashboardFrameError } from "../shell/dashboard-frame";

export type DashboardRouterContext = {
  readonly queryClient: QueryClient;
  readonly locale: string;
};

export const rootRoute = createRootRouteWithContext<DashboardRouterContext>()({
  component: Outlet,
});

/**
 * The signed-in frame. `team` is the dashboard-wide team scope, so every
 * child route's search type includes it.
 */
export const shellRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "shell",
  validateSearch: z.object({ team: z.string().optional() }),
  beforeLoad: async ({ context }) => ({
    session: await context.queryClient.ensureQueryData(sessionQuery),
  }),
  component: DashboardFrame,
  errorComponent: DashboardFrameError,
  pendingComponent: () => <DashboardSkeleton />,
});
