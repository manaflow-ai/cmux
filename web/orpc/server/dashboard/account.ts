import { z } from "zod";
import { loadDashboardBilling } from "@/services/billing/dashboardBilling";
import { loadDashboardTestflight, type DashboardTestflightResponse } from "@/services/billing/dashboardTestflight";
import { isVaultEnabled } from "@/services/vault/config";
import { authed } from "./base";
import { dashboardBillingSchema } from "./schemas/billing";

export const sessionSchema = z.object({
  user: z.object({
    id: z.string(),
    displayName: z.string().nullable(),
    primaryEmail: z.string().nullable(),
    primaryEmailVerified: z.boolean(),
    profileImageUrl: z.string().nullable(),
    selectedTeamId: z.string().nullable(),
  }),
  flags: z.object({ vaultEnabled: z.boolean() }),
});

export type DashboardSession = z.output<typeof sessionSchema>;

/**
 * The signed-in browser user and the build flags the dashboard needs to
 * choose its navigation. `UNAUTHORIZED` sends the SPA to sign-in;
 * `UNAVAILABLE` renders recovery because a Stack outage is not a signed-out
 * session.
 */
const session = authed
  .output(sessionSchema)
  .handler(({ context: { user } }) => ({
    user: {
      id: user.id,
      displayName: user.displayName ?? null,
      primaryEmail: user.primaryEmail ?? null,
      primaryEmailVerified: user.primaryEmailVerified === true,
      profileImageUrl: user.profileImageUrl ?? null,
      selectedTeamId: user.selectedTeam?.id ?? null,
    },
    flags: { vaultEnabled: isVaultEnabled() },
  }));

/** The billing screen: `team` selects the scope (personal entry or a member team). */
const billing = authed
  .input(z.object({ team: z.string().trim().max(200).nullable() }))
  .output(dashboardBillingSchema)
  .handler(({ context, input }) => loadDashboardBilling(context.user, input.team || null));

const testflightSchema = z.object({
  eligible: z.boolean(),
  email: z.string().nullable(),
  status: z.object({
    enrolled: z.boolean(),
    state: z.string().optional(),
    unavailable: z.boolean().optional(),
  }),
}) satisfies z.ZodType<DashboardTestflightResponse>;

/** TestFlight entitlement and enrollment. Join and leave stay form posts to `/api/testflight`. */
const testflight = authed
  .output(testflightSchema)
  .handler(({ context }) => loadDashboardTestflight(context.user));

export const accountRouter = { session, billing, testflight };
