import { createRoute } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
export const homeRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard", component: () => null });
export const homeRoutes = [homeRoute] as const;
