import { z } from "zod";
import { isStackConfigured } from "@/app/lib/stack";
import { loadCoderouterDashboard } from "@/services/coderouter/dashboardOverview";
import { dashboardOS, requireDashboardOrigin } from "./base";
import { dashboardRefusal } from "./errors";
import { coderouterResponseSchema } from "./schemas/coderouter";

/** The overview for `team`, or the Stack-selected team when null. */
export const overview = dashboardOS
  .use(requireDashboardOrigin)
  .input(z.object({ team: z.string().trim().max(200).nullable() }))
  .output(coderouterResponseSchema)
  .handler(async ({ context, input }) => {
    if (!isStackConfigured()) throw dashboardRefusal(404, "not_configured");
    const result = await loadCoderouterDashboard(context.request, input.team ?? undefined);
    switch (result.kind) {
      case "ok":
        return result.body;
      case "missing":
        throw dashboardRefusal(401, "unauthorized");
      case "noTeams":
        throw dashboardRefusal(409, "no_teams");
      case "unavailable":
        throw dashboardRefusal(503, "authorization_unavailable");
    }
  });
