import { createRoute, lazyRouteComponent, redirect } from "@tanstack/react-router";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { isRefusal, refusalReason } from "../lib/refusal";
import { coderouterOverviewQuery } from "../queries/coderouter";
import { CoderouterPageFrame, CoderouterRouteError } from "../screens/coderouter/coderouter-frame";
import { shellRoute } from "./root";

/** `?team=` comes from the shell; absent, the server uses the Stack-selected team. */
const coderouterRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/coderouter",
  staticData: { titleKey: "coderouter.metaTitle" },
  loaderDeps: ({ search }) => ({ team: search.team }),
  loader: async ({ context, deps }) => {
    try {
      await context.queryClient.ensureQueryData(coderouterOverviewQuery(deps.team));
    } catch (error) {
      // No team grants coderouter access: the dashboard home explains why.
      if (isRefusal(error, 409) && refusalReason(error) === "no_teams") {
        throw redirect({ to: "/dashboard" });
      }
      throw error;
    }
  },
  pendingComponent: () => (
    <CoderouterPageFrame>
      <DashboardSectionSkeleton variant="panel" />
    </CoderouterPageFrame>
  ),
  errorComponent: CoderouterRouteError,
  component: lazyRouteComponent(() => import("../screens/coderouter/coderouter-screen"), "CoderouterScreen"),
});

/** Needs only the session user, which the shell already loaded. */
const mobileDevicesRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/mobile-devices",
  component: lazyRouteComponent(
    () => import("../screens/mobile-devices/mobile-devices-screen"),
    "MobileDevicesScreen",
  ),
});

export const coderouterRoutes = [coderouterRoute, mobileDevicesRoute] as const;
