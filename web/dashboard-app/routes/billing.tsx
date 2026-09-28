import { createRoute } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
const billingRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/billing", component: () => null });
const testflightRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/testflight", component: () => null });
export const billingRoutes = [billingRoute, testflightRoute] as const;
