import { useState } from "react";
import type { TaskGoal } from "./goal";
import { useT } from "./i18n";

/** The harness's goal stays visible between turns and after reopening the chat. */
export function TaskGoalStrip({
  goal,
  command,
}: {
  goal: TaskGoal;
  command(action: "pause" | "resume" | "clear"): Promise<unknown>;
}) {
  const t = useT();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const run = async (action: "pause" | "resume" | "clear") => {
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
    <section className="acpmux-goal" data-state={goal.status} aria-label={t("goal.label")} aria-busy={pending}>
      <span className="acpmux-goal-copy">
        <span className="acpmux-goal-state">{t(`goal.${goal.status}`)}</span>
        <span className="acpmux-goal-objective" title={goal.objective}>
          {goal.objective}
        </span>
        {goal.tokenBudget !== undefined && (
          <span className="acpmux-goal-budget">
            {goal.tokensUsed ?? 0} / {goal.tokenBudget}
          </span>
        )}
      </span>
      {goal.status !== "complete" && (
        <button
          type="button"
          disabled={pending}
          onClick={() => void run(goal.status === "active" ? "pause" : "resume")}
        >
          {t(goal.status === "active" ? "replay.pause" : "composer.queueResume")}
        </button>
      )}
      <button type="button" disabled={pending} onClick={() => void run("clear")}>
        {t("inspector.clear")}
      </button>
      {error && (
        <span className="acpmux-goal-error" role="alert">
          {error}
        </span>
      )}
    </section>
  );
}
