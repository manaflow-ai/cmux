import { useState } from "react";
import { usePageNow } from "../../ui/pageClock";
import type { TaskGoal } from "./goal";
import { usePaneLanguage, useT } from "./i18n";

/** When a loop next runs, as the pane's language words a short relative time ("in 4 min."); none
 *  once that time has passed (the run is due or running). */
export function loopNextText(now: number, at: number, lang: string): string | undefined {
  const left = at - now;
  if (left <= 0) return undefined;
  const format = new Intl.RelativeTimeFormat(lang, { style: "short", numeric: "always" });
  if (left < 60_000) return format.format(Math.ceil(left / 1_000), "second");
  if (left < 3_600_000) return format.format(Math.max(1, Math.round(left / 60_000)), "minute");
  if (left < 48 * 3_600_000) return format.format(Math.round(left / 3_600_000), "hour");
  return format.format(Math.round(left / 86_400_000), "day");
}

/** The harness's goal stays visible between turns and after reopening the chat. */
export function TaskGoalStrip({
  goal,
  command,
  now = Date.now,
}: {
  goal: TaskGoal;
  command(action: "pause" | "resume" | "clear"): Promise<unknown>;
  /** The clock a loop's countdown reads (tests pass a fixed one). */
  now?: () => number;
}) {
  return goal.kind === "loop" ? <LoopStrip goal={goal} now={now} /> : <GoalStrip goal={goal} command={command} />;
}

/** A Claude Code /loop: its prompt, that it loops, and its schedule or when it next runs. It has no
 *  controls: Claude Code stops a loop only from inside its own turn (ScheduleWakeup's `stop`,
 *  CronDelete), so a button here could only ask the model, and the person can do that themselves. */
function LoopStrip({ goal, now }: { goal: TaskGoal; now: () => number }) {
  const t = useT();
  const lang = usePaneLanguage();
  // The page's shared second clock (ui/pageClock.ts), only while the next run is ahead: the render
  // after that time passes stops it, as does unmounting, and a hidden page runs no timer.
  // The caption reads the newer of the clock's sample and the time now: a render between the run
  // time and the clock's next tick stops the clock, and its older sample would keep the countdown up.
  const at = goal.nextRunAt;
  const current = now();
  const time = usePageNow(at !== undefined && current < at, now);
  const next = at === undefined ? undefined : loopNextText(Math.max(time, current), at, lang);
  const objective = goal.autonomous ? t("goal.loopAutonomous") : goal.objective;
  return (
    <section className="acpmux-goal" data-state={goal.status} data-kind="loop" aria-label={t("goal.label")}>
      <span className="acpmux-goal-copy">
        <span className="acpmux-goal-state">{t("goal.loop")}</span>
        <span className="acpmux-goal-objective" title={goal.reason ?? objective}>
          {objective}
        </span>
        {goal.schedule && <span className="acpmux-goal-budget">{goal.schedule}</span>}
        {next && (
          <span className="acpmux-goal-budget acpmux-goal-next" title={goal.reason}>
            {next}
          </span>
        )}
      </span>
    </section>
  );
}

function GoalStrip({
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
