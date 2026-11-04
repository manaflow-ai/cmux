/** Provider-neutral long-running work, projected from an ACP harness event. */
export type TaskGoal = {
  objective: string;
  status: "running" | "stalled" | "paused" | "done" | "active" | "blocked" | "usageLimited" | "budgetLimited" | "complete";
  provider?: "codex" | "claude" | "generic";
  startedAt?: number;
  updatedAt?: number;
  endedAt?: number;
  elapsedMs?: number;
  detail?: string;
  steps?: readonly { label: string; status?: string }[];
  tokenBudget?: number;
  tokensUsed?: number;
};

const STATES = new Set([
  "running",
  "stalled",
  "paused",
  "done",
  "active",
  "blocked",
  "usageLimited",
  "budgetLimited",
  "complete",
]);

const STATUS: Record<string, TaskGoal["status"]> = {
  active: "running",
  running: "running",
  blocked: "stalled",
  stalled: "stalled",
  usageLimited: "stalled",
  budgetLimited: "stalled",
  complete: "done",
  done: "done",
  paused: "paused",
};

export function taskGoal(value: unknown): TaskGoal | undefined {
  if (!value || typeof value !== "object") return undefined;
  const goal = value as Record<string, unknown>;
  if (typeof goal.objective !== "string" || !goal.objective.trim() || !STATES.has(String(goal.status)))
    return undefined;
  const count = (value: unknown) => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
  const number = (key: string) =>
    typeof goal[key] === "number" && Number.isFinite(goal[key]) && goal[key] >= 0 ? (goal[key] as number) : undefined;
  const timestamp = (key: string, alias?: string) => {
    const value = number(key) ?? (alias ? number(alias) : undefined);
    if (value === undefined) return undefined;
    return value < 1_000_000_000_000 ? value * 1000 : value;
  };
  const startedAt = timestamp("startedAt", "createdAt");
  const updatedAt = timestamp("updatedAt");
  const endedAt = timestamp("endedAt");
  const elapsedMs = number("elapsedMs") ?? (number("timeUsedSeconds") !== undefined ? number("timeUsedSeconds")! * 1000 : undefined);
  const steps = Array.isArray(goal.steps)
    ? goal.steps.flatMap((step) => {
        if (typeof step === "string" && step.trim()) return [{ label: step }];
        if (!step || typeof step !== "object") return [];
        const value = step as Record<string, unknown>;
        const label = typeof value.label === "string" ? value.label : typeof value.content === "string" ? value.content : undefined;
        return label?.trim()
          ? [{ label, ...(typeof value.status === "string" ? { status: value.status } : {}) }]
          : [];
      })
    : undefined;
  return {
    objective: goal.objective,
    status: STATUS[String(goal.status)] ?? (goal.status as TaskGoal["status"]),
    ...(typeof goal.provider === "string" && ["codex", "claude", "generic"].includes(goal.provider)
      ? { provider: goal.provider as TaskGoal["provider"] }
      : {}),
    ...(startedAt !== undefined ? { startedAt } : {}),
    ...(updatedAt !== undefined ? { updatedAt } : {}),
    ...(endedAt !== undefined ? { endedAt } : {}),
    ...(elapsedMs !== undefined ? { elapsedMs } : {}),
    ...(typeof goal.detail === "string" && goal.detail.trim() ? { detail: goal.detail } : {}),
    ...(steps?.length ? { steps } : {}),
    ...(count(goal.tokenBudget) ? { tokenBudget: goal.tokenBudget as number } : {}),
    ...(count(goal.tokensUsed) ? { tokensUsed: goal.tokensUsed as number } : {}),
  };
}
