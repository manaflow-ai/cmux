import { z } from "zod";
import { teamBillingViewJson } from "@/services/billing/dashboardBilling";
import { loadTeamBillingView } from "@/services/billing/teamBillingView";
import { authed } from "./base";
import { teamBillingViewSchema } from "./schemas/billing";

/**
 * One team's billing panel. The view re-resolves access itself, so a
 * non-member gets `not_found` and a member gets a read-only view.
 */
export const billing = authed
  .input(z.object({ teamId: z.string().trim().min(1).max(200) }))
  .output(teamBillingViewSchema)
  .handler(async ({ context, input }) => teamBillingViewJson(await loadTeamBillingView(context.user, input.teamId)));
