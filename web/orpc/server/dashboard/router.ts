import { accountRouter } from "./account";
import { cloudRouter } from "./cloud";
import { coderouterRouter } from "./coderouter";
import { teamsRouter } from "./teams";
import { vaultRouter } from "./vault";

/**
 * Every call the dashboard SPA makes. Served at `/api/dashboard/rpc` and kept
 * out of the public `/api/v1` OpenAPI router: these are browser procedures,
 * and native clients keep their REST routes.
 */
export const dashboardRouter = {
  account: accountRouter,
  teams: teamsRouter,
  coderouter: coderouterRouter,
  cloud: cloudRouter,
  vault: vaultRouter,
};

export type DashboardRouter = typeof dashboardRouter;
