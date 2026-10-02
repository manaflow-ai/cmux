import { z } from "zod";
import type {
  DashboardBillingResponse,
  PersonalBillingJson,
  TeamBillingViewJson,
} from "@/services/billing/dashboardBilling";
import type { BillingTeamSummary } from "@/services/billing/teamBillingView";

const priceSchema = z.object({
  amountUsd: z.number(),
  interval: z.enum(["month", "year"]),
});

const billingManagementSchema = z.enum(["stripe", "external", "none"]);

export const teamBillingViewSchema = z.discriminatedUnion("status", [
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
      endsAt: z.string().nullable(),
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
    billingSource: z.enum(["stripe", "apple", "none"]),
    manageUrl: z.string().nullable(),
  }),
  subscription: z.object({
    plan: z.string().nullable(),
    status: z.string(),
    currentPeriodEnd: z.string().nullable(),
    cancelAtPeriodEnd: z.boolean(),
    endsAt: z.string().nullable(),
    price: priceSchema.nullable(),
  }).nullable(),
  endedSubscription: z.object({
    plan: z.enum(["go", "pro", "max"]),
    endedAt: z.string().nullable(),
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

export const dashboardBillingSchema = z.object({
  selectedTeamId: z.string(),
  personal: personalBillingSchema.nullable(),
  team: teamBillingViewSchema.nullable(),
  teams: z.array(billingTeamSummarySchema).readonly(),
}) satisfies z.ZodType<DashboardBillingResponse>;
