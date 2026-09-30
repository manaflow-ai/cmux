import { createRoute, lazyRouteComponent } from "@tanstack/react-router";
import { shellRoute } from "./root";

const pages = () => import("../screens/settings/settings-pages");

/** Account settings. Sections read the Stack client SDK; the shell gates the session. */
const settingsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/settings",
  component: lazyRouteComponent(() => import("../screens/settings/settings-layout"), "SettingsLayout"),
});

const profileRoute = createRoute({
  getParentRoute: () => settingsRoute,
  path: "/",
  component: lazyRouteComponent(pages, "SettingsProfilePage"),
});

const authRoute = createRoute({
  getParentRoute: () => settingsRoute,
  path: "/auth",
  component: lazyRouteComponent(pages, "SettingsAuthPage"),
});

const notificationsRoute = createRoute({
  getParentRoute: () => settingsRoute,
  path: "/notifications",
  component: lazyRouteComponent(pages, "SettingsNotificationsPage"),
});

const sessionsRoute = createRoute({
  getParentRoute: () => settingsRoute,
  path: "/sessions",
  component: lazyRouteComponent(pages, "SettingsSessionsPage"),
});

const apiKeysRoute = createRoute({
  getParentRoute: () => settingsRoute,
  path: "/api-keys",
  component: lazyRouteComponent(pages, "SettingsApiKeysPage"),
});

const accountRoute = createRoute({
  getParentRoute: () => settingsRoute,
  path: "/account",
  component: lazyRouteComponent(pages, "SettingsAccountPage"),
});

export const settingsRoutes = [
  settingsRoute.addChildren([profileRoute, authRoute, notificationsRoute, sessionsRoute, apiKeysRoute, accountRoute]),
] as const;
