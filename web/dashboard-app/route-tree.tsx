import { billingRoutes } from "./routes/billing";
import { coderouterRoutes } from "./routes/coderouter";
import { homeRoutes } from "./routes/home";
import { redirectRoutes } from "./routes/redirects";
import { rootRoute, shellRoute } from "./routes/root";
import { settingsRoutes } from "./routes/settings";
import { teamsRoutes } from "./routes/teams";
import { vaultRoutes } from "./routes/vault";

export const routeTree = rootRoute.addChildren([
  shellRoute.addChildren([
    ...homeRoutes,
    ...redirectRoutes,
    ...billingRoutes,
    ...coderouterRoutes,
    ...settingsRoutes,
    ...teamsRoutes,
    ...vaultRoutes,
  ]),
]);
