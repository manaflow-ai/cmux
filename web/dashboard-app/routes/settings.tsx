import { createRoute, type ErrorComponentProps, lazyRouteComponent } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { RouteSectionError } from "../components/route-section-error";
import {
  settingsApiKeysQuery,
  settingsNotificationsQuery,
  settingsOAuthProvidersQuery,
  settingsOverviewQuery,
  settingsSessionsQuery,
} from "../queries/settings";
import { SettingsHeader, type SettingsHeaderSection } from "../screens/settings/settings-header";
import { shellRoute } from "./root";

const pages = () => import("../screens/settings/settings-pages");

/**
 * The settings navigation stays, and each page's own header paints at once;
 * only the section below it waits or fails.
 */
function sectionStates(section: SettingsHeaderSection, skeleton: ReactNode) {
  return {
    pendingComponent: () => (
      <>
        <SettingsHeader section={section} />
        {skeleton}
      </>
    ),
    errorComponent: (props: ErrorComponentProps) => (
      <>
        <SettingsHeader section={section} />
        <RouteSectionError {...props} />
      </>
    ),
  };
}

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
  ...sectionStates("profile", <DashboardSectionSkeleton variant="settings" rows={2} />),
  path: "/",
  component: lazyRouteComponent(pages, "SettingsProfilePage"),
});

const authRoute = createRoute({
  getParentRoute: () => settingsRoute,
  ...sectionStates("auth", <DashboardSectionSkeleton variant="settings" />),
  path: "/auth",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsOverviewQuery), queryClient.prefetchQuery(settingsOAuthProvidersQuery)),
  component: lazyRouteComponent(pages, "SettingsAuthPage"),
});

const notificationsRoute = createRoute({
  getParentRoute: () => settingsRoute,
  ...sectionStates("notifications", <DashboardSectionSkeleton variant="table" columns={2} rows={2} />),
  path: "/notifications",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsNotificationsQuery)),
  component: lazyRouteComponent(pages, "SettingsNotificationsPage"),
});

const sessionsRoute = createRoute({
  getParentRoute: () => settingsRoute,
  ...sectionStates("sessions", <DashboardSectionSkeleton variant="table" columns={4} />),
  path: "/sessions",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsSessionsQuery)),
  component: lazyRouteComponent(pages, "SettingsSessionsPage"),
});

const apiKeysRoute = createRoute({
  getParentRoute: () => settingsRoute,
  ...sectionStates("apiKeys", <DashboardSectionSkeleton variant="table" columns={5} rows={3} />),
  path: "/api-keys",
  loader: async ({ context: { queryClient } }) => {
    await queryClient.prefetchQuery(settingsOverviewQuery);
    // The key list exists only when the project allows user API keys.
    if (queryClient.getQueryData(settingsOverviewQuery.queryKey)?.project.allowUserApiKeys) {
      await queryClient.prefetchQuery(settingsApiKeysQuery);
    }
  },
  component: lazyRouteComponent(pages, "SettingsApiKeysPage"),
});

const accountRoute = createRoute({
  getParentRoute: () => settingsRoute,
  ...sectionStates("account", <DashboardSectionSkeleton variant="settings" rows={2} />),
  path: "/account",
  loader: ({ context: { queryClient } }) => settled(queryClient.prefetchQuery(settingsOverviewQuery)),
  component: lazyRouteComponent(pages, "SettingsAccountPage"),
});

export const settingsRoutes = [
  settingsRoute.addChildren([profileRoute, authRoute, notificationsRoute, sessionsRoute, apiKeysRoute, accountRoute]),
] as const;
