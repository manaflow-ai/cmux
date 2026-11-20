import type { AcpmuxPlanEntry, AcpmuxSnapshot } from "./model";

export type LiveProgress = NonNullable<AcpmuxSnapshot["progress"]>;

/// Keeps the Session Info projection stable across token snapshots. A new object is needed only
/// when the checklist changes or the turn crosses its terminal boundary.
export function projectLiveProgress(
  previous: LiveProgress | undefined,
  plan: readonly AcpmuxPlanEntry[] | undefined,
  working: boolean,
): LiveProgress | undefined {
  if (!plan || plan.length === 0) return undefined;
  if (previous && previous.plan === plan && Boolean(previous.ended) !== working) return previous;
  return {
    plan: plan as AcpmuxPlanEntry[],
    completed: plan.filter((entry) => entry.status === "completed").length,
    total: plan.length,
    ...(working ? {} : { ended: true }),
  };
}
