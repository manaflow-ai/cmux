import { createRoute, lazyRouteComponent, redirect } from "@tanstack/react-router";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { RouteSectionError } from "../components/route-section-error";
import { isRefusal, refusalReason } from "../lib/refusal";
import { cloudDevicesQuery } from "../queries/cloud";
import { coderouterOverviewQuery } from "../queries/coderouter";
import { CloudPageFrame } from "../screens/cloud/cloud-frame";
import { CoderouterPageFrame } from "../screens/coderouter/coderouter-frame";
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
  errorComponent: (props) => (
    <CoderouterPageFrame>
      <RouteSectionError {...props} />
    </CoderouterPageFrame>
  ),
  component: lazyRouteComponent(() => import("../screens/coderouter/coderouter-screen"), "CoderouterScreen"),
});

const cloudRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/cloud",
  loader: ({ context }) => context.queryClient.ensureQueryData(cloudDevicesQuery),
  pendingComponent: () => (
    <CloudPageFrame>
      <DashboardSectionSkeleton variant="devices" />
    </CloudPageFrame>
  ),
  // A 503 here is the device list failing, not the session: it shows in the
  // page like any other data failure, never as sign-in recovery.
  errorComponent: (props) => (
    <CloudPageFrame>
      <RouteSectionError {...props} />
    </CloudPageFrame>
  ),
  component: lazyRouteComponent(() => import("../screens/cloud/cloud-screen"), "CloudScreen"),
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

export const coderouterRoutes = [coderouterRoute, cloudRoute, mobileDevicesRoute] as const;
