import {
  createRoute,
  lazyRouteComponent,
  redirect,
  useLocation,
  type ErrorComponentProps,
} from "@tanstack/react-router";
import { DashboardAuthRecovery, SignInRedirect } from "../components/auth-recovery";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { isDashboardApiError } from "../lib/api";
import { cloudDevicesQuery } from "../queries/cloud";
import { coderouterOverviewQuery } from "../queries/coderouter";
import { CloudPageFrame } from "../screens/cloud/cloud-frame";
import { CoderouterLoadError, CoderouterPageFrame } from "../screens/coderouter/coderouter-frame";
import { DashboardRouteError } from "../shell/dashboard-frame";
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
      if (isDashboardApiError(error, 409) && error.code === "no_teams") {
        throw redirect({ to: "/dashboard" });
      }
      throw error;
    }
  },
  pendingComponent: () => (
    <CoderouterPageFrame>
      <DashboardSectionSkeleton />
    </CoderouterPageFrame>
  ),
  errorComponent: CoderouterRouteError,
  component: lazyRouteComponent(() => import("../screens/coderouter/coderouter-screen"), "CoderouterScreen"),
});

const cloudRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/cloud",
  loader: ({ context }) => context.queryClient.ensureQueryData(cloudDevicesQuery),
  pendingComponent: () => (
    <CloudPageFrame>
      <DashboardSectionSkeleton variant="rows" />
    </CloudPageFrame>
  ),
  errorComponent: CloudRouteError,
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

/** 401 goes to sign-in; an account-service outage keeps the header and explains it. */
function CoderouterRouteError(props: ErrorComponentProps) {
  const location = useLocation();
  if (isDashboardApiError(props.error, 401)) return <SignInRedirect returnPath={location.href} />;
  if (isDashboardApiError(props.error, 503)) {
    return (
      <CoderouterPageFrame>
        <CoderouterLoadError />
      </CoderouterPageFrame>
    );
  }
  return <DashboardRouteError {...props} />;
}

/** 401 goes to sign-in; a Stack outage or throttle renders recovery in place. */
function CloudRouteError(props: ErrorComponentProps) {
  const location = useLocation();
  if (isDashboardApiError(props.error, 401)) return <SignInRedirect returnPath={location.href} />;
  if (isDashboardApiError(props.error, 503) || isDashboardApiError(props.error, 429)) {
    return <DashboardAuthRecovery returnPath={location.href} />;
  }
  return <DashboardRouteError {...props} />;
}

export const coderouterRoutes = [coderouterRoute, cloudRoute, mobileDevicesRoute] as const;
