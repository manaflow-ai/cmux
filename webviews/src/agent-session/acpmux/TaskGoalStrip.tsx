import { useId, useState } from "react";
import { usePageNow } from "../../ui/pageClock";
import type { TaskGoal } from "./goal";
import { usePaneLanguage, useT } from "./i18n";
import { Clock, Expand, PauseCircle, PlayTriangle } from "./conversation/icons";
import { formatDuration } from "./conversation/turns";
import { useNow } from "./subagents/subagentGroupModel";
import "./TaskGoalStrip.css";
import { loopNextText } from "./taskGoalStripModel";
/** The harness's goal stays visible between turns and after reopening the chat. */
export function TaskGoalStrip({
  goal,
  harness,
  command,
  now = Date.now,
}: {
  goal: TaskGoal;
  /** The session harness fills in provider metadata for legacy persisted goals. */
  harness?: string;
  command(action: "pause" | "resume" | "delete"): Promise<unknown>;
  /** The clock a loop's countdown reads (tests pass a fixed one). */
  now?: () => number;
}) {
  return goal.kind === "loop" ? (
    <LoopStrip goal={goal} now={now} />
  ) : (
    <GoalStrip goal={goal} harness={harness} command={command} />
  );
}

/** A Claude Code /loop between its runs, as one quiet chip in the composer's column: when it checks
 *  back ("Checking back in 15 min."), or an interval loop's schedule ("Repeats every 5 minutes"). Its prompt is the agent's own wake text (a
 *  ScheduleWakeup `prompt` can be a long internal brief with job ids, links and step lists), never
 *  shown inline (cmux#38051): it reads in the chip's tooltip and, on demand, in the panel its button
 *  opens, wrapped to the column. It has no other controls: Claude Code stops a loop only from inside
 *  its own turn (ScheduleWakeup's `stop`, CronDelete), so a button here could only ask the model, and
 *  the person can do that themselves. */
function LoopStrip({ goal, now }: { goal: TaskGoal; now: () => number }) {
  const t = useT();
  const lang = usePaneLanguage();
  const [expanded, setExpanded] = useState(false);
  const panelId = useId();
  // The page's shared second clock (ui/pageClock.ts), only while the next run is ahead: the render
  // after that time passes stops it, as does unmounting, and a hidden page runs no timer.
  // The caption reads the newer of the clock's sample and the time now: a render between the run
  // time and the clock's next tick stops the clock, and its older sample would keep the countdown up.
  const at = goal.nextRunAt;
  const current = now();
  const time = usePageNow(at !== undefined && current < at && !goal.schedule, now);
  const next = at === undefined ? undefined : loopNextText(Math.max(time, current), at, lang);
  // An interval loop says its schedule ("Repeats every 5 minutes"), a self-wake when it checks back.
  const label = goal.schedule
    ? t("goal.loopSchedule", { schedule: goal.schedule })
    : next
      ? t("goal.loopNext", { when: next })
      : t("goal.loop");
  const prompt = goal.autonomous ? undefined : goal.objective.trim() || undefined;
  const tooltip = [prompt ?? t("goal.loopAutonomous"), goal.reason].filter(Boolean).join("\n\n");
  const hasDetails = Boolean(prompt || goal.reason || goal.steps?.length || goal.detail);
  return (
    <section className="acpmux-goal" data-state={goal.status} data-kind="loop" aria-label={t("goal.label")}>
      <span className="acpmux-goal-copy" title={tooltip}>
        <span className="acpmux-goal-loop-mark" aria-hidden="true">
          <Clock size={14} />
        </span>
        <span className="acpmux-goal-state acpmux-goal-loop-label">{label}</span>
      </span>
      {hasDetails && (
        <button
          type="button"
          className="acpmux-goal-action"
          aria-expanded={expanded}
          aria-controls={expanded ? panelId : undefined}
          aria-label={t("goal.loopPrompt")}
          title={t("goal.loopPrompt")}
          onClick={() => setExpanded((value) => !value)}
        >
          <Expand size={16} />
        </button>
      )}
      {expanded && (
        <div className="acpmux-goal-details acpmux-goal-loop-details" id={panelId}>
          {prompt && <p className="acpmux-goal-loop-prompt">{prompt}</p>}
          {goal.reason && <p>{goal.reason}</p>}
          {goal.detail && <p>{goal.detail}</p>}
          {goal.steps?.map((step, index) => (
            <div className="acpmux-goal-step" key={`${step.label}-${index}`} data-status={step.status}>
              <span aria-hidden="true">{step.status === "done" || step.status === "completed" ? "✓" : "·"}</span>
              <span>{step.label}</span>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function GoalStrip({
  goal,
  harness,
  command,
}: {
  goal: TaskGoal;
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
  // Goals without provider metadata are legacy Codex payloads. A named Claude or
  // other harness stays read-only until it exposes a real lifecycle action.
  const provider = goal.provider ?? harnessProvider ?? (!harness ? "codex" : undefined);
  const canControl = provider === "codex";
  const live = goal.status === "running" || goal.status === "active";
  const current = useNow(live);
  const start = goal.startedAt;
  const elapsed =
    goal.elapsedMs !== undefined
      ? goal.elapsedMs + (live && goal.updatedAt !== undefined ? Math.max(0, current - goal.updatedAt) : 0)
      : start !== undefined
        ? Math.max(0, (goal.endedAt ?? (live ? current : (goal.updatedAt ?? current))) - start)
        : undefined;
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
          aria-label={
            goal.status === "running" || goal.status === "active" ? t("replay.pause") : t("composer.queueResume")
          }
          title={goal.status === "running" || goal.status === "active" ? t("replay.pause") : t("composer.queueResume")}
          onClick={() => void run(goal.status === "running" || goal.status === "active" ? "pause" : "resume")}
        >
          {goal.status === "running" || goal.status === "active" ? (
            <PauseCircle size={16} />
          ) : (
            <PlayTriangle size={16} style={{ color: "inherit" }} />
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
          <Expand size={16} />
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
