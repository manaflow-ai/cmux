import { createRoute } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
const vaultRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/vault", component: () => null });
const sessionsRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/vault/sessions", component: () => null });
const sessionRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/vault/sessions/$id", component: () => null });
const cliAuthRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/vault/cli-auth", component: () => null });
export const vaultRoutes = [vaultRoute, sessionsRoute, sessionRoute, cliAuthRoute] as const;
