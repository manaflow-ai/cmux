import { createRoute, lazyRouteComponent } from "@tanstack/react-router";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import {
  settingsApiKeysQuery,
  settingsNotificationsQuery,
  settingsOAuthProvidersQuery,
  settingsOverviewQuery,
  settingsSessionsQuery,
} from "../queries/settings";
import { shellRoute } from "./root";

const pages = () => import("../screens/settings/settings-pages");

/** The settings layout (header and navigation) stays; only the section waits. */
const sectionPending = () => <DashboardSectionSkeleton variant="rows" />;

/**
 * Wait for a page's reads before it renders. `prefetchQuery` never throws, so
 * a failed read still surfaces in that section's own error boundary.
 */
async function settled(...prefetches: readonly Promise<void>[]): Promise<void> {
  await Promise.all(prefetches);
}

/**
 * Account settings. Sections read typed oRPC queries (prefetched here and by
 * the page's server render); writes use the Hexclave client SDK.
 */
const settingsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/settings",
  component: lazyRouteComponent(() => import("../screens/settings/settings-layout"), "SettingsLayout"),
});

const profileRoute = createRoute({
  getParentRoute: () => settingsRoute,
  pendingComponent: sectionPending,
  path: "/",
  component: lazyRouteComponent(pages, "SettingsProfilePage"),
});

const authRoute = createRoute({
  getParentRoute: () => settingsRoute,
  pendingComponent: sectionPending,
  path: "/auth",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsOverviewQuery), queryClient.prefetchQuery(settingsOAuthProvidersQuery)),
  component: lazyRouteComponent(pages, "SettingsAuthPage"),
});

const notificationsRoute = createRoute({
  getParentRoute: () => settingsRoute,
  pendingComponent: sectionPending,
  path: "/notifications",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsNotificationsQuery)),
  component: lazyRouteComponent(pages, "SettingsNotificationsPage"),
});

const sessionsRoute = createRoute({
  getParentRoute: () => settingsRoute,
  pendingComponent: sectionPending,
  path: "/sessions",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsSessionsQuery)),
  component: lazyRouteComponent(pages, "SettingsSessionsPage"),
});

const apiKeysRoute = createRoute({
  getParentRoute: () => settingsRoute,
  pendingComponent: sectionPending,
  path: "/api-keys",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsOverviewQuery), queryClient.prefetchQuery(settingsApiKeysQuery)),
  component: lazyRouteComponent(pages, "SettingsApiKeysPage"),
});

const accountRoute = createRoute({
  getParentRoute: () => settingsRoute,
  pendingComponent: sectionPending,
  path: "/account",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsOverviewQuery)),
  component: lazyRouteComponent(pages, "SettingsAccountPage"),
});

export const settingsRoutes = [
  settingsRoute.addChildren([profileRoute, authRoute, notificationsRoute, sessionsRoute, apiKeysRoute, accountRoute]),
] as const;
