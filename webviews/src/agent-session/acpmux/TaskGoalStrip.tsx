import { useState } from "react";
import { usePageNow } from "../../ui/pageClock";
import type { TaskGoal } from "./goal";
import { usePaneLanguage, useT } from "./i18n";
import { Expand, PauseCircle, PlayTriangle } from "./conversation/icons";
import { formatDuration } from "./conversation/turns";
import { useNow } from "./subagents/SubagentGroup";
import "./TaskGoalStrip.css";

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

/** A Claude Code /loop: its prompt, that it loops, and its schedule or when it next runs. It has no
 *  controls: Claude Code stops a loop only from inside its own turn (ScheduleWakeup's `stop`,
 *  CronDelete), so a button here could only ask the model, and the person can do that themselves. */
function LoopStrip({ goal, now }: { goal: TaskGoal; now: () => number }) {
  const t = useT();
  const lang = usePaneLanguage();
  const [expanded, setExpanded] = useState(false);
  // The page's shared second clock (ui/pageClock.ts), only while the next run is ahead: the render
  // after that time passes stops it, as does unmounting, and a hidden page runs no timer.
  const at = goal.nextRunAt;
  const time = usePageNow(at !== undefined && now() < at, now);
  const next = at === undefined ? undefined : loopNextText(time, at, lang);
  const objective = goal.autonomous ? t("goal.loopAutonomous") : goal.objective;
  const hasDetails = Boolean(goal.steps?.length || goal.detail);
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
      {hasDetails && (
        <button
          type="button"
          className="acpmux-goal-action"
          aria-expanded={expanded}
          aria-label={t("goal.label")}
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
