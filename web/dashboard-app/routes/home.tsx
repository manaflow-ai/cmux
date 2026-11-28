import { createRoute, lazyRouteComponent } from "@tanstack/react-router";
import { shellRoute } from "./root";

export const homeRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard",
  component: lazyRouteComponent(() => import("../screens/home/home-screen"), "HomeScreen"),
});

export const homeRoutes = [homeRoute] as const;
