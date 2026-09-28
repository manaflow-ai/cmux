import { createRoute } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
const coderouterRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/coderouter", component: () => null });
const cloudRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/cloud", component: () => null });
const mobileDevicesRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/mobile-devices", component: () => null });
export const coderouterRoutes = [coderouterRoute, cloudRoute, mobileDevicesRoute] as const;
