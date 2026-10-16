import { createRoute, redirect } from "@tanstack/react-router";
import { legacyTeamHashRedirect } from "./legacy-team-hash";
import { shellRoute } from "./root";

// Renamed dashboard URLs. Saved links and bookmarks keep working; the
// redirects replace history so Back skips the legacy URL.

/** Old names of CodeRouter. `?team=` survives the redirect. */
const aiAccountsRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/ai-accounts",
  beforeLoad: ({ search }) => {
    throw redirect({ to: "/dashboard/coderouter", search: { team: search.team }, replace: true });
  },
});

const subrouterRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/subrouter",
  beforeLoad: ({ search }) => {
    throw redirect({ to: "/dashboard/coderouter", search: { team: search.team }, replace: true });
  },
});

/** The device-management page before its public rename. */
const irohRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/iroh",
  beforeLoad: () => {
    throw redirect({ to: "/dashboard/mobile-devices", replace: true });
  },
});

/** Legacy Hexclave account settings, addressed by URL hash. */
const legacyTeamRoute = createRoute({
  getParentRoute: () => shellRoute,
  path: "/dashboard/team",
  beforeLoad: ({ location }) => {
    throw legacyTeamHashRedirect(location.hash);
  },
});

export const redirectRoutes = [aiAccountsRoute, subrouterRoute, irohRoute, legacyTeamRoute] as const;
