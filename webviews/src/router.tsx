import {
  createHashHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
} from "@tanstack/react-router";
import type { ReactNode } from "react";

type WebviewRouteComponent = () => ReactNode;

export function createWebviewsRouter(WebviewComponent: WebviewRouteComponent) {
  const rootRoute = createRootRoute({
    component: Outlet,
    notFoundComponent: WebviewComponent,
  });
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: WebviewComponent,
  });
  const diffRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/diff",
    component: WebviewComponent,
  });
  const generatedDiffRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/cmux-diff-viewer",
    component: WebviewComponent,
  });
  const agentSessionRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/agent-session",
    component: WebviewComponent,
  });
  const routeTree = rootRoute.addChildren([
    indexRoute,
    diffRoute,
    generatedDiffRoute,
    agentSessionRoute,
  ]);
  return createRouter({
    history: createHashHistory(),
    routeTree,
  });
}

type WebviewsRouter = ReturnType<typeof createWebviewsRouter>;

declare module "@tanstack/react-router" {
  interface Register {
    router: WebviewsRouter;
  }
}
