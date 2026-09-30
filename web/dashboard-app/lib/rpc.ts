import { createORPCClient } from "@orpc/client";
import { RPCLink } from "@orpc/client/fetch";
import type { RouterClient } from "@orpc/server";
import { createTanstackQueryUtils } from "@orpc/tanstack-query";
import type { DashboardRouter } from "@/orpc/server/dashboard/router";

export type DashboardClient = RouterClient<DashboardRouter>;

const link = new RPCLink({
  url: () => new URL("/api/dashboard/rpc", window.location.origin),
});

/** The browser client of the dashboard procedures; types come from the server router. */
export const dashboardClient: DashboardClient = createORPCClient(link);

/** `queryOptions` / `mutationOptions` / keys for every dashboard procedure. */
export const rpc = createTanstackQueryUtils(dashboardClient, { path: ["dashboard"] });
