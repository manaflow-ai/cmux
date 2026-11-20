import { createRoute, lazyRouteComponent, notFound } from "@tanstack/react-router";
import { DashboardSectionSkeleton } from "../components/dashboard-skeleton";
import { isRefusal } from "../lib/refusal";
import { cloudVmHealthQuery } from "../queries/ops";
import { CloudVmHealthFrame, CloudVmHealthRouteError } from "../screens/ops/cloud-vm-health-frame";
import { shellRoute } from "./root";

/** Staff-only: the admin gate's 403 (and any 404) is a page that does not exist. */
function notFoundForNonStaff(error: unknown): never {
  if (isRefusal(error, 403) || isRefusal(error, 404)) throw notFound();
  throw error;
}

const cloudVmHealthRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/ops/cloud-vms",
  loader: ({ context }) =>
    context.queryClient.ensureQueryData(cloudVmHealthQuery).catch(notFoundForNonStaff),
  pendingComponent: () => (
    <CloudVmHealthFrame>
      <DashboardSectionSkeleton variant="table" columns={6} rows={4} />
    </CloudVmHealthFrame>
  ),
  errorComponent: CloudVmHealthRouteError,
  component: lazyRouteComponent(() => import("../screens/ops/cloud-vm-health"), "CloudVmHealthScreen"),
});

export const opsRoutes = [cloudVmHealthRoute] as const;
