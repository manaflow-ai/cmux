import { isStale, type RunEntry } from "./runs";
import type { HomeRun } from "./types";

export type HomeGoalState = "working" | "stalled" | "failed";

/** A view-only goal projection until the owner exposes a first-class HomeGoal. */
export interface HomeGoal {
  run: HomeRun;
  state: HomeGoalState;
  title: string;
  detail?: string;
}

/** Pick the newest unresolved run, keeping the strip quiet for completed work. */
export function projectGoal(entries: readonly RunEntry[], now: number): HomeGoal | undefined {
  for (const entry of entries) {
    const { run } = entry;
    if (run.status !== "running" && run.status !== "failed") continue;
    const stale = isStale(run, now);
    const state: HomeGoalState = run.status === "failed" ? "failed" : stale ? "stalled" : "working";
    return {
      run,
      state,
      title: run.title || run.answers[0] || "Current goal",
      detail: run.error || (stale ? "No update from this run" : undefined),
    };
  }
  return undefined;
}
