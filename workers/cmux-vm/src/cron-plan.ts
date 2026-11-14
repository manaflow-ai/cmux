/**
 * What the Worker's cron (wrangler.jsonc triggers, every 5 minutes in preview, staging and production) runs in each
 * environment, by the exact configured ENVIRONMENT (parseEnvironment reads a missing or unknown one as production, so
 * this never does).
 *
 *  - The tunnel sweep (src/upstream/orphan-sweep.ts) runs wherever the VM API runs: a revoke's 200 is final because
 *    this sweep deletes any device tunnel that lands after it. It deletes only on its own database's positive record
 *    (an attempt resolved, or an intent revoked, for that tenant and device), and device ids are fresh per create, so
 *    preview Workers, which share the environment name "preview" and its slugs, never delete one another's tunnels.
 *  - The VM sweep deletes VMs no ownership row records, the absence of a row: in preview another Worker's VM has no
 *    row here, so it runs only where one Worker owns the environment (staging and production).
 *  - The agent reaper runs in staging and production, as before the preview cron existed.
 */
export interface CronPlan {
  readonly reap: boolean;
  readonly sweepVms: boolean;
  readonly sweepTunnels: boolean;
}

export const cronPlan = (environment: string | undefined): CronPlan => {
  switch (environment) {
    case "staging":
    case "production":
      return { reap: true, sweepVms: true, sweepTunnels: true };
    case "preview":
      return { reap: false, sweepVms: false, sweepTunnels: true };
    default:
      return { reap: false, sweepVms: false, sweepTunnels: false };
  }
};
