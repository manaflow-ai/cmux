/** The harness's goal, projected from its reported state: Codex's persisted thread goal, or
 * (`kind: "loop"`) a Claude Code /loop that acpmux reads from its ScheduleWakeup and CronCreate
 * calls (cmux-tui acpmux `claude_stdio/loops.rs`). */
export type TaskGoal = {
  /** A Claude Code /loop; absent for a Codex goal. */
  kind?: "loop";
  objective: string;
  status:
    | "running"
    | "stalled"
    | "paused"
    | "done"
    | "active"
    | "blocked"
    | "usageLimited"
    | "budgetLimited"
    | "complete";
  provider?: "codex" | "claude" | "generic";
  startedAt?: number;
  updatedAt?: number;
  endedAt?: number;
  elapsedMs?: number;
  detail?: string;
  steps?: readonly { label: string; status?: string }[];
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
  const loop = goal.kind === "loop";
  const autonomous = loop && goal.autonomous === true;
  if (typeof goal.objective !== "string" || !STATES.has(String(goal.status))) return undefined;
  if (!goal.objective.trim() && !autonomous) return undefined;
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
  const elapsedMs =
    number("elapsedMs") ?? (number("timeUsedSeconds") !== undefined ? number("timeUsedSeconds")! * 1000 : undefined);
  const steps = Array.isArray(goal.steps)
    ? goal.steps.flatMap((step) => {
        if (typeof step === "string" && step.trim()) return [{ label: step }];
        if (!step || typeof step !== "object") return [];
        const value = step as Record<string, unknown>;
        const label =
          typeof value.label === "string" ? value.label : typeof value.content === "string" ? value.content : undefined;
        return label?.trim() ? [{ label, ...(typeof value.status === "string" ? { status: value.status } : {}) }] : [];
      })
    : undefined;
  const text = (value: unknown) => typeof value === "string" && value.trim() !== "";
  return {
    ...(loop ? { kind: "loop" as const } : {}),
    objective: goal.objective,
    // Claude loops retain their scheduling status (`active`) for the loop strip;
    // provider-owned goals use the shared running/stalled/done vocabulary.
    status: loop
      ? (goal.status as TaskGoal["status"])
      : (STATUS[String(goal.status)] ?? (goal.status as TaskGoal["status"])),
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
    ...(autonomous ? { autonomous: true as const } : {}),
    ...(loop && text(goal.reason) ? { reason: goal.reason as string } : {}),
    ...(loop && count(goal.nextRunAt) ? { nextRunAt: goal.nextRunAt as number } : {}),
    ...(loop && text(goal.schedule) ? { schedule: goal.schedule as string } : {}),
  };
}
