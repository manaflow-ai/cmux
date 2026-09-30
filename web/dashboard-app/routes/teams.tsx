import { createRoute, lazyRouteComponent } from "@tanstack/react-router";
import { z } from "zod";
import { DashboardSectionSkeleton, DashboardSkeleton } from "../components/dashboard-skeleton";
import { teamBillingQuery } from "../queries/billing";
import { teamApiKeysQuery, teamCatalogQuery, teamDetailQuery } from "../queries/teams";
import { shellRoute } from "./root";

const teamsList = () => import("../screens/teams/teams-list");
const teamShell = () => import("../screens/teams/team-shell");

const teamsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/teams",
  loader: ({ context }) => context.queryClient.ensureQueryData(teamCatalogQuery),
  pendingComponent: () => <DashboardSkeleton variant="rows" />,
  component: lazyRouteComponent(teamsList, "TeamsPage"),
  errorComponent: lazyRouteComponent(teamsList, "TeamsPageError"),
});

const newTeamRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/teams/new",
  component: lazyRouteComponent(() => import("../screens/teams/new-team-flow"), "NewTeamPage"),
});

/** Team layout: header and tabs. 403/404 from the detail render "not found". */
const teamRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/teams/$teamId",
  loader: ({ context, params }) => context.queryClient.ensureQueryData(teamDetailQuery(params.teamId)),
  pendingComponent: () => <DashboardSkeleton variant="rows" />,
  component: lazyRouteComponent(teamShell, "TeamShell"),
  errorComponent: lazyRouteComponent(teamShell, "TeamShellError"),
});

const teamGeneralRoute = createRoute({
  getParentRoute: () => teamRoute,
  path: "/",
  component: lazyRouteComponent(() => import("../screens/teams/team-general"), "TeamGeneral"),
});

const teamMembersRoute = createRoute({
  getParentRoute: () => teamRoute,
  path: "/members",
  component: lazyRouteComponent(() => import("../screens/teams/team-members"), "TeamMembers"),
});

const teamApiKeysRoute = createRoute({
  getParentRoute: () => teamRoute,
  path: "/api-keys",
  // A refusal (no permission) renders inside the panel, so the prefetch never throws.
  loader: ({ context, params }) => context.queryClient.prefetchQuery(teamApiKeysQuery(params.teamId)),
  pendingComponent: () => <DashboardSectionSkeleton />,
  component: lazyRouteComponent(() => import("../screens/teams/team-api-keys"), "TeamApiKeys"),
});

const teamBillingRoute = createRoute({
  getParentRoute: () => teamRoute,
  path: "/billing",
  validateSearch: z.object({ welcome: z.string().optional() }),
  loader: ({ context, params }) => context.queryClient.ensureQueryData(teamBillingQuery(params.teamId)),
  // The team header and tabs stay; only the billing panel waits.
  pendingComponent: () => <DashboardSectionSkeleton />,
  component: lazyRouteComponent(() => import("../screens/teams/team-billing"), "TeamBillingTab"),
});

/** Email invitation landing (`services/teams/origin.ts` builds the URL). */
const acceptRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/team/accept",
  validateSearch: z.object({ code: z.string().optional() }),
  component: lazyRouteComponent(() => import("../screens/teams/accept-invite"), "AcceptInvitePage"),
});

export const teamsRoutes = [
  teamsRoute,
  newTeamRoute,
  teamRoute.addChildren([teamGeneralRoute, teamMembersRoute, teamApiKeysRoute, teamBillingRoute]),
  acceptRoute,
] as const;
