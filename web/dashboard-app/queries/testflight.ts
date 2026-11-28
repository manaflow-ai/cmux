import { rpc } from "../lib/rpc";

export type { DashboardTestflightResponse } from "@/services/billing/dashboardTestflight";

/**
 * Entitlement and enrollment. Always refetched on mount so a lapsed
 * subscription or a join/leave redirect shows the current state.
 */
export const testflightQuery = rpc.account.testflight.queryOptions({ staleTime: 0 });
