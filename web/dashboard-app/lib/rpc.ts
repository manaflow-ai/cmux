import { createORPCClient } from "@orpc/client";
import { RPCLink } from "@orpc/client/fetch";
import type { RouterClient } from "@orpc/server";
import { createTanstackQueryUtils } from "@orpc/tanstack-query";
import type { DashboardRouter } from "@/orpc/server/dashboard/router";

/** Per-call options the dashboard passes to the RPC link. */
export type DashboardClientContext = {
  /** Abort the call after this many milliseconds. */
  readonly timeoutMs?: number;
};

export type DashboardClient = RouterClient<DashboardRouter, DashboardClientContext>;

const link = new RPCLink<DashboardClientContext>({
  url: () => new URL("/api/dashboard/rpc", globalThis.location?.origin ?? "http://localhost"),
  fetch: async (request, init, { context }) => {
    const timeoutMs = context.timeoutMs;
    if (timeoutMs === undefined) return fetch(request, init);
    const expiry = new AbortController();
    const timer = setTimeout(() => expiry.abort(new Error("Dashboard request timed out")), timeoutMs);
    try {
      return await fetch(request, { ...init, signal: AbortSignal.any([request.signal, expiry.signal]) });
    } finally {
      clearTimeout(timer);
    }
  },
});

/** The browser client of the dashboard procedures; types come from the server router. */
export const dashboardClient: DashboardClient = createORPCClient(link);

/** `queryOptions` / `mutationOptions` / keys for every dashboard procedure. */
export const rpc = createTanstackQueryUtils(dashboardClient, { path: ["dashboard"] });
