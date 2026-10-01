import { createRootRouteWithContext, Outlet } from "@tanstack/react-router";
import type { RouterContext } from "../router.tsx";

export const Route = createRootRouteWithContext<RouterContext>()({
  beforeLoad: ({ context }) => context.session.auth.load(),
  component: Outlet,
});
