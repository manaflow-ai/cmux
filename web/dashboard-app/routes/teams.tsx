import { createRoute, lazyRouteComponent } from "@tanstack/react-router";
import { z } from "zod";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { teamBillingQuery } from "../queries/billing";
import { teamApiKeysQuery, teamCatalogQuery, teamDetailQuery } from "../queries/teams";
import { TeamBillingRouteError, TeamShellPending, TeamsPageFrame, TeamsRouteError } from "../screens/teams/teams-frame";
import { shellRoute } from "./root";
import { settingsHubRoute } from "./settings";

const teamsList = () => import("../screens/teams/teams-list");
const teamShell = () => import("../screens/teams/team-shell");

const teamsRoute = createRoute({
  getParentRoute: () => settingsHubRoute,
  path: "/dashboard/teams",
  loader: ({ context }) => context.queryClient.ensureQueryData(teamCatalogQuery),
  pendingComponent: () => (
    <TeamsPageFrame namespace="dashboard.teams.list">
      <DashboardSectionSkeleton variant="list" rows={3} />
    </TeamsPageFrame>
  ),
  component: lazyRouteComponent(teamsList, "TeamsPage"),
  errorComponent: TeamsRouteError,
});

const newTeamRoute = createRoute({
  getParentRoute: () => settingsHubRoute,
  path: "/dashboard/teams/new",
  component: lazyRouteComponent(() => import("../screens/teams/new-team-flow"), "NewTeamPage"),
});

/** Team layout: header and tabs. 403/404 from the detail render "not found". */
const teamRoute = createRoute({
  getParentRoute: () => settingsHubRoute,
  path: "/dashboard/teams/$teamId",
  loader: ({ context, params }) => context.queryClient.ensureQueryData(teamDetailQuery(params.teamId)),
  pendingComponent: TeamShellPending,
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
  pendingComponent: () => <DashboardSectionSkeleton variant="table" columns={5} rows={3} />,
  component: lazyRouteComponent(() => import("../screens/teams/team-api-keys"), "TeamApiKeys"),
});

const teamBillingRoute = createRoute({
  getParentRoute: () => teamRoute,
  path: "/billing",
  validateSearch: z.object({ welcome: z.string().optional() }),
  loader: ({ context, params }) => context.queryClient.ensureQueryData(teamBillingQuery(params.teamId)),
  // The team header and tabs stay; only the billing panel waits or fails.
  pendingComponent: () => <DashboardSectionSkeleton variant="panel" />,
  errorComponent: TeamBillingRouteError,
  component: lazyRouteComponent(() => import("../screens/teams/team-billing"), "TeamBillingTab"),
});

/** Email invitation landing (`services/teams/origin.ts` builds the URL). */
const acceptRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/team/accept",
  validateSearch: z.object({ code: z.string().optional() }),
  component: lazyRouteComponent(() => import("../screens/teams/accept-invite"), "AcceptInvitePage"),
});

/** Team pages live inside the Settings hub; the invitation landing does not. */
export const hubTeamsRoutes = [
  teamsRoute,
  newTeamRoute,
  teamRoute.addChildren([teamGeneralRoute, teamMembersRoute, teamApiKeysRoute, teamBillingRoute]),
] as const;

export const teamsRoutes = [acceptRoute] as const;
