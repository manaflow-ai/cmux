/** Codex's persisted thread goal, projected from its reported state. */
export type TaskGoal = {
  objective: string;
  status: "active" | "paused" | "blocked" | "usageLimited" | "budgetLimited" | "complete";
  tokenBudget?: number;
  tokensUsed?: number;
};

const STATES = new Set(["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"]);

export function taskGoal(value: unknown): TaskGoal | undefined {
  if (!value || typeof value !== "object") return undefined;
  const goal = value as Record<string, unknown>;
  if (typeof goal.objective !== "string" || !goal.objective.trim() || !STATES.has(String(goal.status)))
    return undefined;
  const count = (value: unknown) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
  return {
    objective: goal.objective,
    status: goal.status as TaskGoal["status"],
    ...(count(goal.tokenBudget) ? { tokenBudget: goal.tokenBudget as number } : {}),
    ...(count(goal.tokensUsed) ? { tokensUsed: goal.tokensUsed as number } : {}),
  };
}
