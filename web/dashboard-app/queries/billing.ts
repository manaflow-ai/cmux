import { type QueryClient, useMutation, useQueryClient } from "@tanstack/react-query";
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

/** The viewer's personal plan: the account menu badge and upgrade prompts. */
export const planQuery = rpc.billing.current.queryOptions({ staleTime: 60_000 });

/** What switching to `plan` costs; fetched when the switch dialog opens. */
export function planChangePreviewQuery(plan: "pro" | "max") {
  return rpc.billing.previewChange.queryOptions({ input: { plan }, staleTime: 0, gcTime: 0 });
}

/** Every billing read a plan change or cancellation can affect. */
async function refreshBilling(queryClient: QueryClient): Promise<void> {
  await Promise.all([
    queryClient.invalidateQueries({ queryKey: rpc.account.billing.key() }),
    queryClient.invalidateQueries({ queryKey: rpc.teams.billing.key() }),
    queryClient.invalidateQueries({ queryKey: rpc.billing.current.key() }),
  ]);
}

export function useChangePlan() {
  const queryClient = useQueryClient();
  return useMutation(rpc.billing.change.mutationOptions({ onSuccess: () => refreshBilling(queryClient) }));
}

export function useCancelPlan() {
  const queryClient = useQueryClient();
  return useMutation(rpc.billing.cancel.mutationOptions({ onSuccess: () => refreshBilling(queryClient) }));
}

export function useResumePlan() {
  const queryClient = useQueryClient();
  return useMutation(rpc.billing.resume.mutationOptions({ onSuccess: () => refreshBilling(queryClient) }));
}
