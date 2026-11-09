import type { AcpmuxPlanEntry, AcpmuxRow } from "../model";

/// The plan Progress draws: its steps, and whether the turn that wrote them has ended. `done` is the
/// steps already counted where the plan was published (liveProgress.ts), so no render counts again.
export type SessionInfoPlan = {
  readonly entries: readonly AcpmuxPlanEntry[];
  readonly ended: boolean;
  readonly done?: number;
};

/// The chat's current plan: its latest plan row with steps. It has ended when the chat is not working
/// or a later prompt came after it (a new turn's plan is a new row, direct.ts). The scan walks back
/// from the newest row and stops at the first plan, so a chat with a plan reads only its last turn.
export function currentPlan(rows: readonly AcpmuxRow[], working: boolean): SessionInfoPlan | undefined {
  let later = false;
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "plan" && row.plan && row.plan.length > 0) return { entries: row.plan, ended: !working || later };
    if (row.kind === "user") later = true;
  }
  return undefined;
}

/// How many of the plan's steps are done.
export const planDone = (plan: SessionInfoPlan) =>
  plan.done ?? plan.entries.filter((entry) => entry.status === "completed").length;
