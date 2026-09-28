import {
  teamBillingViewJson,
  type TeamBillingViewJson,
} from "@/services/billing/dashboardBilling";
import { withDashboardSessionUser } from "@/services/billing/dashboardSessionRoute";
import { loadTeamBillingView } from "@/services/billing/teamBillingView";

type RouteContext = { params: Promise<{ teamId: string }> };

/**
 * One team's billing panel. The view re-resolves access itself, so a
 * non-member gets `not_found` and a member gets a read-only view.
 */
export async function GET(request: Request, context: RouteContext): Promise<Response> {
  const { teamId } = await context.params;
  return withDashboardSessionUser(request, async (user): Promise<TeamBillingViewJson> =>
    teamBillingViewJson(await loadTeamBillingView(user, teamId))
  );
}
