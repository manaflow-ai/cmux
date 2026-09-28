import { queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import type {
  DashboardBillingResponse,
  PersonalBillingJson,
  TeamBillingViewJson,
} from "@/services/billing/dashboardBilling";
import type { BillingTeamSummary } from "@/services/billing/teamBillingView";
import { dashboardFetch } from "../lib/api";

const priceSchema = z.object({
  amountUsd: z.number(),
  interval: z.enum(["month", "year"]),
});

const billingManagementSchema = z.enum(["stripe", "none"]);

const teamBillingViewSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("ready"),
    team: z.object({ id: z.string(), displayName: z.string().nullable() }),
    role: z.enum(["admin", "member"]),
    canManageBilling: z.boolean(),
    planId: z.string(),
    billingManagement: billingManagementSchema,
    granted: z.boolean(),
    subscription: z.object({
      status: z.string(),
      seats: z.number().nullable(),
      currentPeriodEnd: z.string().nullable(),
      cancelAtPeriodEnd: z.boolean(),
      price: priceSchema.nullable(),
    }).nullable(),
    seats: z.number().nullable(),
    memberCount: z.number().nullable(),
    overSeat: z.boolean(),
    paymentPastDue: z.boolean(),
  }),
  z.object({ status: z.literal("personal") }),
  z.object({ status: z.literal("not_found"), teamId: z.string() }),
  z.object({ status: z.literal("unavailable"), teamId: z.string() }),
]) satisfies z.ZodType<TeamBillingViewJson>;

const personalBillingSchema = z.object({
  planStatus: z.object({
    isPro: z.boolean(),
    planId: z.string(),
    billingManagement: billingManagementSchema,
  }),
  subscription: z.object({
    plan: z.string().nullable(),
    status: z.string(),
    currentPeriodEnd: z.string().nullable(),
    cancelAtPeriodEnd: z.boolean(),
    price: priceSchema.nullable(),
  }).nullable(),
  goPlanEnabled: z.boolean(),
  hasPaidManualGrant: z.boolean(),
  vaultEnabled: z.boolean(),
}) satisfies z.ZodType<PersonalBillingJson>;

const billingTeamSummarySchema = z.object({
  id: z.string(),
  displayName: z.string().nullable(),
  personal: z.boolean(),
  planId: z.string().nullable(),
}) satisfies z.ZodType<BillingTeamSummary>;

const dashboardBillingSchema = z.object({
  selectedTeamId: z.string(),
  personal: personalBillingSchema.nullable(),
  team: teamBillingViewSchema.nullable(),
  teams: z.array(billingTeamSummarySchema),
}) satisfies z.ZodType<DashboardBillingResponse>;

export type { DashboardBillingResponse, PersonalBillingJson, TeamBillingViewJson };

/** The billing screen for the dashboard team scope (`?team=`). */
export function dashboardBillingQuery(team: string | undefined) {
  const teamId = team?.trim() || null;
  return queryOptions({
    queryKey: ["dashboard", "billing", teamId] as const,
    queryFn: ({ signal }) =>
      dashboardFetch(
        teamId ? `/api/dashboard/billing?team=${encodeURIComponent(teamId)}` : "/api/dashboard/billing",
        dashboardBillingSchema,
        { signal },
      ),
  });
}

/** One team's billing panel, shared by the billing and team screens. */
export function teamBillingQuery(teamId: string) {
  return queryOptions({
    queryKey: ["dashboard", "team-billing", teamId] as const,
    queryFn: ({ signal }) =>
      dashboardFetch(`/api/teams/${encodeURIComponent(teamId)}/billing`, teamBillingViewSchema, { signal }),
  });
}
