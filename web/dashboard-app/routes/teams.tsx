import { createRoute, Outlet } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
const teamsRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/teams", component: () => null });
const newTeamRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/teams/new", component: () => null });
const teamRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/teams/$teamId", component: Outlet });
const teamChild = <P extends string>(path: P) => createRoute({ getParentRoute: () => teamRoute, path, component: () => null });
const acceptRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/team/accept", component: () => null });
export const teamsRoutes = [
  teamsRoute,
  newTeamRoute,
  teamRoute.addChildren([teamChild("/"), teamChild("/members"), teamChild("/api-keys"), teamChild("/billing")]),
  acceptRoute,
] as const;
