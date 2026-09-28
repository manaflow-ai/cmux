import { createRoute, Outlet } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
const settingsRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/settings", component: Outlet });
const child = <P extends string>(path: P) => createRoute({ getParentRoute: () => settingsRoute, path, component: () => null });
export const settingsRoutes = [
  settingsRoute.addChildren([child("/"), child("/auth"), child("/notifications"), child("/sessions"), child("/api-keys"), child("/account")]),
] as const;
