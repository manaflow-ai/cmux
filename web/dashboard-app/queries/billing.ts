import { rpc } from "../lib/rpc";

export type {
  DashboardBillingResponse,
  PersonalBillingJson,
  TeamBillingViewJson,
} from "@/services/billing/dashboardBilling";

/** The billing screen for the dashboard team scope (`?team=`). */
export function dashboardBillingQuery(team: string | undefined) {
  return rpc.account.billing.queryOptions({ input: { team: team?.trim() || null } });
}

/** One team's billing panel, shared by the billing and team screens. */
export function teamBillingQuery(teamId: string) {
  return rpc.teams.billing.queryOptions({ input: { teamId } });
}
