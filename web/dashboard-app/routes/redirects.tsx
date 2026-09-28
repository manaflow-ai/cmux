import { createRoute } from "@tanstack/react-router";
import { shellRoute } from "./root";

// PLACEHOLDER: replaced by the section port.
const aiAccountsRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/ai-accounts", component: () => null });
const subrouterRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/subrouter", component: () => null });
const irohRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/iroh", component: () => null });
const legacyTeamRoute = createRoute({ getParentRoute: () => shellRoute, path: "/dashboard/team", component: () => null });
export const redirectRoutes = [aiAccountsRoute, subrouterRoute, irohRoute, legacyTeamRoute] as const;
