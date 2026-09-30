import { queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import type { DashboardTestflightResponse } from "@/services/billing/dashboardTestflight";
import { dashboardFetch } from "../lib/api";

const testflightSchema = z.object({
  eligible: z.boolean(),
  email: z.string().nullable(),
  status: z.object({
    enrolled: z.boolean(),
    state: z.string().optional(),
    unavailable: z.boolean().optional(),
  }),
}) satisfies z.ZodType<DashboardTestflightResponse>;

export type { DashboardTestflightResponse };

/**
 * Entitlement and enrollment. Always refetched on mount so a lapsed
 * subscription or a join/leave redirect shows the current state.
 */
export const testflightQuery = queryOptions({
  queryKey: ["dashboard", "testflight"] as const,
  queryFn: ({ signal }) => dashboardFetch("/api/testflight", testflightSchema, { signal }),
  staleTime: 0,
});
