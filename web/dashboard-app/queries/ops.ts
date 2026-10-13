import { rpc } from "../lib/rpc";

/** The newest stored Cloud VM health sweep. Staff only; the cron refreshes it every five minutes. */
export const cloudVmHealthQuery = rpc.ops.cloudVmHealth.queryOptions({
  refetchInterval: 60_000,
});
