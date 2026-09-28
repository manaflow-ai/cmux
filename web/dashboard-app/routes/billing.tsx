import { createRoute, lazyRouteComponent } from "@tanstack/react-router";
import { z } from "zod";
import { dashboardBillingQuery } from "../queries/billing";
import { testflightQuery } from "../queries/testflight";
import { shellRoute } from "./root";

/** `?billing=` and `?welcome=` come from billing redirects; `team` from the shell. */
export const billingRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/billing",
  validateSearch: z.object({
    billing: z.string().optional(),
    welcome: z.string().optional(),
    interval: z.string().optional(),
  }),
  loaderDeps: ({ search }) => ({ team: search.team }),
  loader: ({ context, deps }) => context.queryClient.ensureQueryData(dashboardBillingQuery(deps.team)),
  component: lazyRouteComponent(() => import("../screens/billing/billing-route"), "BillingRouteComponent"),
});

/** `?testflight=` is the result banner set by the join/leave redirect. */
export const testflightRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/testflight",
  validateSearch: z.object({ testflight: z.string().optional() }),
  // Not awaited: the header paints at once and the section suspends on the
  // query, matching the old streamed page.
  loader: ({ context }) => {
    void context.queryClient.prefetchQuery(testflightQuery);
  },
  component: lazyRouteComponent(() => import("../screens/testflight/testflight-route"), "TestflightRouteComponent"),
});

export const billingRoutes = [billingRoute, testflightRoute] as const;
