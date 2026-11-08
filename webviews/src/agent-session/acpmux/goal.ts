/** The harness's goal, projected from its reported state: Codex's persisted thread goal, or
 * (`kind: "loop"`) a Claude Code /loop that acpmux reads from its ScheduleWakeup and CronCreate
 * calls (cmux-tui acpmux `claude_stdio/loops.rs`). */
export type TaskGoal = {
  /** A Claude Code /loop; absent for a Codex goal. */
  kind?: "loop";
  objective: string;
  status: "active" | "paused" | "blocked" | "usageLimited" | "budgetLimited" | "complete";
  tokenBudget?: number;
  tokensUsed?: number;
  /** A loop's: an autonomous /loop, which has no prompt of the person's. */
  autonomous?: true;
  /** A loop's: why Claude chose its delay (ScheduleWakeup's `reason`). */
  reason?: string;
  /** A loop's: when it next runs, epoch ms. */
  nextRunAt?: number;
  /** A cron loop's schedule, as Claude Code words it ("every 5 minutes"). */
  schedule?: string;
};

const STATES = new Set(["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]);

export function taskGoal(value: unknown): TaskGoal | undefined {
  if (!value || typeof value !== "object") return undefined;
  const goal = value as Record<string, unknown>;
  const loop = goal.kind === "loop";
  const autonomous = loop && goal.autonomous === true;
  if (typeof goal.objective !== "string" || !STATES.has(String(goal.status))) return undefined;
  if (!goal.objective.trim() && !autonomous) return undefined;
  const count = (value: unknown) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
  const text = (value: unknown) => typeof value === "string" && value.trim() !== "";
  return {
    ...(loop ? { kind: "loop" as const } : {}),
    objective: goal.objective,
    status: goal.status as TaskGoal["status"],
    ...(count(goal.tokenBudget) ? { tokenBudget: goal.tokenBudget as number } : {}),
    ...(count(goal.tokensUsed) ? { tokensUsed: goal.tokensUsed as number } : {}),
    ...(autonomous ? { autonomous: true as const } : {}),
    ...(loop && text(goal.reason) ? { reason: goal.reason as string } : {}),
    ...(loop && count(goal.nextRunAt) ? { nextRunAt: goal.nextRunAt as number } : {}),
    ...(loop && text(goal.schedule) ? { schedule: goal.schedule as string } : {}),
  };
}
