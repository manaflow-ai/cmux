import { rpc } from "../lib/rpc";

/** The newest stored VM Health sweep. Staff only; the cron refreshes it every five minutes. */
export const cloudVmHealthQuery = rpc.ops.cloudVmHealth.queryOptions({
  refetchInterval: 60_000,
});
