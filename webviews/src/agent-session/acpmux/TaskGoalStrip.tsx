import { useState } from "react";
import type { TaskGoal } from "./goal";
import { useT } from "./i18n";
import { Expand, PauseCircle, PlayTriangle } from "./conversation/icons";
import { formatDuration } from "./conversation/turns";
import { useNow } from "./subagents/SubagentGroup";
import "./TaskGoalStrip.css";

/** The harness's goal stays visible between turns and after reopening the chat. */
export function TaskGoalStrip({
  goal,
  harness,
  command,
}: {
  goal: TaskGoal;
  /** The session harness fills in provider metadata for legacy persisted goals. */
  harness?: string;
  command(action: "pause" | "resume" | "delete"): Promise<unknown>;
}) {
  const t = useT();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [expanded, setExpanded] = useState(false);
  const harnessProvider = harness?.toLowerCase().startsWith("codex")
    ? "codex"
    : harness?.toLowerCase().startsWith("claude")
      ? "claude"
      : undefined;
  const provider = goal.provider ?? harnessProvider;
  const canControl = provider === "codex";
  const live = goal.status === "running" || goal.status === "active";
  const now = useNow(live);
  const start = goal.startedAt;
  const elapsed =
    goal.elapsedMs ??
    (start !== undefined
      ? Math.max(0, (goal.endedAt ?? (live ? now : goal.updatedAt ?? now)) - start)
      : undefined);
  const status =
    goal.status === "running" || goal.status === "active"
      ? t("goal.active")
      : goal.status === "done" || goal.status === "complete"
        ? t("goal.complete")
        : goal.status === "paused"
          ? t("goal.paused")
          : t("goal.blocked");
  const run = async (action: "pause" | "resume" | "delete") => {
    if (pending) return;
    setPending(true);
    setError(undefined);
    try {
      await command(action);
    } catch (error) {
      setError(error instanceof Error ? error.message : String(error));
    } finally {
      setPending(false);
    }
  };
  return (
    <section
      className="acpmux-goal"
      data-state={goal.status}
      data-provider={provider}
      aria-label={t("goal.label")}
      aria-busy={pending}
    >
      <span className="acpmux-goal-mark" aria-hidden="true">
        <span>◎</span>
      </span>
      <span className="acpmux-goal-copy">
        <span className="acpmux-goal-state">{status}</span>
        <span className="acpmux-goal-objective" title={goal.objective}>
          {goal.objective}
        </span>
        {goal.tokenBudget !== undefined && (
          <span className="acpmux-goal-budget">
            {goal.tokensUsed ?? 0} / {goal.tokenBudget}
          </span>
        )}
      </span>
      {elapsed !== undefined && <time className="acpmux-goal-time">{formatDuration(elapsed)}</time>}
      {canControl && goal.status !== "done" && goal.status !== "complete" && (
        <button
          type="button"
          className="acpmux-goal-action"
          disabled={pending}
          aria-label={goal.status === "running" || goal.status === "active" ? t("replay.pause") : t("composer.queueResume")}
          title={goal.status === "running" || goal.status === "active" ? t("replay.pause") : t("composer.queueResume")}
          onClick={() => void run(goal.status === "running" || goal.status === "active" ? "pause" : "resume")}
        >
          {goal.status === "running" || goal.status === "active" ? (
            <PauseCircle size={16} />
          ) : (
            <PlayTriangle size={16} />
          )}
        </button>
      )}
      {canControl && (
        <button
          type="button"
          className="acpmux-goal-action"
          disabled={pending}
          aria-label={t("inspector.clear")}
          title={t("inspector.clear")}
          onClick={() => void run("delete")}
        >
          <span aria-hidden="true">×</span>
        </button>
      )}
      {(goal.steps?.length || goal.detail) && (
        <button
          type="button"
          className="acpmux-goal-action"
          aria-expanded={expanded}
          aria-label={expanded ? t("inspector.clear") : t("goal.label")}
          title={t("goal.label")}
          onClick={() => setExpanded((value) => !value)}
        >
          <Expand size={15} />
        </button>
      )}
      {expanded && (
        <div className="acpmux-goal-details">
          {goal.detail && <p>{goal.detail}</p>}
          {goal.steps?.map((step, index) => (
            <div className="acpmux-goal-step" key={`${step.label}-${index}`} data-status={step.status}>
              <span aria-hidden="true">{step.status === "done" || step.status === "completed" ? "✓" : "·"}</span>
              <span>{step.label}</span>
            </div>
          ))}
        </div>
      )}
      {error && (
        <span className="acpmux-goal-error" role="alert">
          {error}
        </span>
      )}
    </section>
  );
}
