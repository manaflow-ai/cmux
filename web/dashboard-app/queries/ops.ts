import { useMutation, useQueryClient } from "@tanstack/react-query";
import { rpc } from "../lib/rpc";

/** The newest stored VM Health sweep. Staff only; the cron refreshes it every five minutes. */
export const cloudVmHealthQuery = rpc.ops.cloudVmHealth.queryOptions({
  refetchInterval: 60_000,
});

/** Every paywall and pricing experiment. Staff only; the optimizer writes it once a day. */
export const paywallLabQuery = rpc.ops.paywallLab.queryOptions({
  refetchInterval: 60_000,
});

/** The Paywall Lab kill switch. */
export function usePaywallLabSetPaused() {
  const queryClient = useQueryClient();
  return useMutation(rpc.ops.paywallLabSetPaused.mutationOptions({
    onSuccess: () => queryClient.invalidateQueries({ queryKey: rpc.ops.paywallLab.key() }),
  }));
}
