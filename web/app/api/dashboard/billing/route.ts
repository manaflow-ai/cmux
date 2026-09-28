import {
  loadDashboardBilling,
  type DashboardBillingResponse,
} from "@/services/billing/dashboardBilling";
import { withDashboardSessionUser } from "@/services/billing/dashboardSessionRoute";

/**
 * The billing screen for the signed-in user. `?team=` selects the scope:
 * the personal entry returns `personal`, a member team returns `team`.
 */
export async function GET(request: Request): Promise<Response> {
  const requestedTeamId = new URL(request.url).searchParams.get("team");
  return withDashboardSessionUser(request, async (user): Promise<DashboardBillingResponse> =>
    loadDashboardBilling(user, requestedTeamId)
  );
}
