import { accountRouter } from "./account";
import { billingRouter } from "./billing";
import { cloudRouter } from "./cloud";
import { coderouterRouter } from "./coderouter";
import { settingsRouter } from "./settings";
import { teamsRouter } from "./teams";
import { vaultRouter } from "./vault";

/**
 * Every call the dashboard SPA makes. Served at `/api/dashboard/rpc` and kept
 * out of the public `/api/v1` OpenAPI router: these are browser procedures,
 * and native clients keep their REST routes.
 */
export const dashboardRouter = {
  account: accountRouter,
  billing: billingRouter,
  teams: teamsRouter,
  coderouter: coderouterRouter,
  cloud: cloudRouter,
  vault: vaultRouter,
  settings: settingsRouter,
};

export type DashboardRouter = typeof dashboardRouter;
