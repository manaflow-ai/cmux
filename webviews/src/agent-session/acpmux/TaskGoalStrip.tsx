import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import { Tooltip } from "../../ui/Tooltip";
import { Clock as ClockText } from "../../ui/Typography";
import { usePageNow } from "../../ui/pageClock";
import type { TaskGoal } from "./goal";
import { usePaneLanguage, useT } from "./i18n";
import { ChevronDown, Clock, Close, Expand, PauseCircle, Pencil, PlayTriangle } from "./conversation/icons";
import { formatDuration } from "./conversation/turns";
import { goalHatPlace } from "./goalHat.experiment";
import { cssTimeMs } from "./conversation/fold";
import { useNow } from "./subagents/subagentGroupModel";
import { motionAllowed } from "./subagents/trayMotionModel";
import "./TaskGoalStrip.css";
import { goalUpdatedText, loopNextText } from "./taskGoalStripModel";
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
  command(action: GoalCommand, objective?: string): Promise<unknown>;
  /** The clock a loop's countdown and a goal's "Updated" read (tests pass a fixed one). */
  now?: () => number;
}) {
  return goal.kind === "loop" ? (
    <LoopStrip goal={goal} now={now} />
  ) : (
    <GoalStrip goal={goal} harness={harness} command={command} now={now} />
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

/** What the goal row asks the chat for: Codex's own `/goal` subcommands, and `edit` (a new
 *  objective, which `/goal <text>` sets in place of the old one). */
export type GoalCommand = "pause" | "resume" | "delete" | "edit";

/** The chat's goal as a row of the composer hat (Leo, 2026-11-09, on a reference goal pill: "i
 *  wonder hwo we wanna have it with the composer hat"). Folded, it is one line: the state, the
 *  objective cut to the row, the elapsed time in tabular figures and its buttons. A pointer resting
 *  on a cut objective shows the whole goal in a hover card that covers nothing of the row's layout.
 *  A click on the line opens it in place: the objective's first line stays where it was while the
 *  rest of the text and the "Updated" line unfold under it, the card growing upward on one height
 *  transition that the next click turns around from wherever it is (no queue, no dropped click).
 *  Edit swaps the objective for a field of the same type, in the same place. */
function GoalStrip({
  goal,
  harness,
  command,
  now,
}: {
  goal: TaskGoal;
  harness?: string;
  command(action: GoalCommand, objective?: string): Promise<unknown>;
  now: () => number;
}) {
  const t = useT();
  const lang = usePaneLanguage();
  const [place] = useState(() => experimentArm(goalHatPlace));
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [open, setOpen] = useState(false);
  // The objective clamps back to one cut line only once the fold has closed over it: clamping at
  // the click would drop its lower lines before the height that hides them moved.
  const [clamped, setClamped] = useState(true);
  const [draft, setDraft] = useState<string>();
  const [cut, setCut] = useState(false);
  const bodyId = useId();
  const clip = useRef<HTMLDivElement>(null);
  const text = useRef<HTMLSpanElement>(null);
  const field = useRef<HTMLTextAreaElement>(null);
  const trail = useRef<HTMLSpanElement>(null);
  const editing = draft !== undefined;
  const shown = open || editing;
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
  const done = goal.status === "done" || goal.status === "complete";
  const status = live
    ? t("goal.headRunning")
    : done
      ? t("goal.headMet")
      : goal.status === "paused"
        ? t("goal.headPaused")
        : t("goal.headStalled");
  const updated = goal.updatedAt !== undefined ? goalUpdatedText(now(), goal.updatedAt, lang) : undefined;
  const run = async (action: GoalCommand, objective?: string) => {
    if (pending) return false;
    setPending(true);
    setError(undefined);
    try {
      await command(action, objective);
      return true;
    } catch (error) {
      setError(error instanceof Error ? error.message : String(error));
      return false;
    } finally {
      setPending(false);
    }
  };
  // perf-hot: 16ms goal-hat-toggle
  // The fold is CSS (TaskGoalStrip.css `.acpmux-goal-clip`): its one grid row moves between 0fr and
  // 1fr on the open and close curves, so a click mid-way turns it around from where it is drawn and
  // nothing queues, and open it follows the text as the pane rewraps it or the field grows. No script
  // measures it (it read the box, its text and forced a reflow on every click; Leo, 2026-11-11: "the
  // composer hat the way it switches between text is ugly bc it's too slow on the transitions"). This
  // only clamps the objective back to one cut line once the fold has closed over it.
  useLayoutEffect(() => {
    const box = clip.current;
    if (!box || shown || clamped) return;
    // No motion (the gate, Reduce Motion, a page away, or a 0 ms token): at once. A style read.
    const still =
      !motionAllowed(box) ||
      (cssTimeMs(box.ownerDocument.defaultView?.getComputedStyle(box).transitionDuration ?? "0s") ?? 0) === 0;
    if (still) {
      setClamped(true);
      return;
    }
    // A click mid-way that opens it again removes these first. A cancel settles only when no
    // transition runs any more (the host turned motion off), never on a reversal (review of
    // cmux#39151, F1).
    const settle = (event: TransitionEvent) => {
      if (event.target !== box || event.propertyName !== "grid-template-rows") return;
      if (event.type === "transitioncancel" && box.getAnimations().length > 0) return;
      setClamped(true);
    };
    box.addEventListener("transitionend", settle);
    box.addEventListener("transitioncancel", settle);
    return () => {
      box.removeEventListener("transitionend", settle);
      box.removeEventListener("transitioncancel", settle);
    };
  }, [shown, clamped]);
  // The time and chevron's width, which the objective's first line leaves free, as the trail's own
  // observer reports it after layout (a unit added to the time widens it): never read in a render.
  useLayoutEffect(() => keepTrailWidth(trail.current), []);
  // Open, the text takes the pointer so the wheel scrolls a long goal (review of cmux#39151, F1). A
  // click on it (not a selection, not on a button or the field) still folds it, as the line's button
  // does; keyboard users fold with that button or Escape. Removed with the open state.
  useEffect(() => {
    const box = clip.current;
    if (!shown || editing || !box) return;
    const fold = (event: MouseEvent) => {
      if ((event.target as Element).closest("button, textarea")) return;
      if (box.ownerDocument.getSelection()?.isCollapsed === false) return;
      setOpen(false);
      setClamped(false);
    };
    box.addEventListener("click", fold);
    return () => box.removeEventListener("click", fold);
  }, [shown, editing]);
  // The field takes focus in the commit that draws it, the caret after the text.
  useLayoutEffect(() => {
    const node = field.current;
    if (!editing || !node) return;
    node.focus();
    node.setSelectionRange(node.value.length, node.value.length);
  }, [editing]);
  // A cut objective is what the hover card is for: measured by the line's observer after layout (its
  // first report, then whenever the line's width changes: a pane narrowed or widened; review of
  // cmux#39151, F2), when the text changes and while folded. The observer goes with the folded state
  // or the row.
  useLayoutEffect(() => {
    const node = text.current;
    if (!node) return;
    if (!clamped || shown || typeof ResizeObserver === "undefined") {
      setCut(false);
      return;
    }
    const observer = new ResizeObserver(() => setCut(node.scrollWidth > node.clientWidth + 0.5));
    observer.observe(node);
    return () => observer.disconnect();
  }, [goal.objective, clamped, shown]);
  const toggle = () => {
    if (editing) return;
    setOpen((value) => !value);
    setClamped(false);
  };
  const edit = () => {
    setDraft(goal.objective);
    setClamped(false);
  };
  const cancel = () => setDraft(undefined);
  const save = async () => {
    const objective = draft?.trim();
    if (!objective || objective === goal.objective.trim()) return cancel();
    if (await run("edit", objective)) setDraft(undefined);
  };
  const objective = editing ? (
    <textarea
      ref={field}
      className="acpmux-goal-field"
      value={draft}
      rows={1}
      maxLength={4000}
      aria-label={t("goal.editLabel")}
      disabled={pending}
      onChange={(event) => setDraft(event.target.value)}
      onKeyDown={(event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          cancel();
        } else if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
          event.preventDefault();
          void save();
        }
      }}
    />
  ) : (
    <span ref={text} className="acpmux-goal-objective">
      {goal.objective}
    </span>
  );
  return (
    <section
      className="acpmux-goal"
      data-look={place}
      data-state={goal.status}
      data-provider={provider}
      data-open={shown || undefined}
      data-clamped={(clamped && !shown) || undefined}
      data-editing={editing || undefined}
      aria-label={t("goal.label")}
      aria-busy={pending}
    >
      <span className="acpmux-goal-mark" aria-hidden="true">
        <span />
      </span>
      <span className="acpmux-goal-state">{status}</span>
      <div className="acpmux-goal-clip" ref={clip}>
        <div className="acpmux-goal-content" id={bodyId}>
          {/* Holds the first line's end for the time and buttons; the lines under it run full width. */}
          <span className="acpmux-goal-spacer" aria-hidden="true" />
          {objective}
          <div className="acpmux-goal-meta" aria-hidden={!shown}>
            {updated && <span>{t("goal.updated", { when: updated })}</span>}
            {goal.tokenBudget !== undefined && (
              <span className="acpmux-goal-budget">
                {goal.tokensUsed ?? 0} / {goal.tokenBudget}
              </span>
            )}
            {editing && (
              <span className="acpmux-goal-edit-actions">
                <button type="button" className="acpmux-goal-text-action" onClick={cancel} disabled={pending}>
                  {t("goal.editCancel")}
                </button>
                <button
                  type="button"
                  className="acpmux-goal-text-action"
                  data-primary
                  onClick={() => void save()}
                  disabled={pending || !draft?.trim()}
                >
                  {t("goal.editSave")}
                </button>
              </span>
            )}
          </div>
          {goal.detail && <p className="acpmux-goal-detail">{goal.detail}</p>}
          {goal.steps?.map((step, index) => (
            <div className="acpmux-goal-step" key={`${step.label}-${index}`} data-status={step.status}>
              <span aria-hidden="true">{step.status === "done" || step.status === "completed" ? "✓" : "·"}</span>
              <span>{step.label}</span>
            </div>
          ))}
        </div>
      </div>
      {/* The whole line is the fold's control, under the text and over nothing else: the buttons
          and the field sit above it. */}
      {/* A pointer resting on a cut line shows the whole goal over the stack (the tooltip layer, so
          nothing in the hat moves); open, the text is there and the card stays away. */}
      <Tooltip
        disabled={!cut}
        className="ui-card acpmux-goal-preview"
        label={<span className="acpmux-goal-preview-text">{goal.objective}</span>}
        detail={updated ? t("goal.updated", { when: updated }) : undefined}
      >
        <button
          type="button"
          className="acpmux-goal-toggle"
          aria-expanded={shown}
          aria-controls={bodyId}
          aria-label={goal.objective}
          disabled={editing}
          onClick={toggle}
          onKeyDown={(event) => {
            if (event.key !== "Escape" || !open) return;
            event.stopPropagation();
            toggle();
          }}
        />
      </Tooltip>
      {/* The buttons stand over the cut objective's end (it fades under them) while the pointer is on
          the row or focus is in it, and always while it is open: showing them moves nothing. */}
      <span className="acpmux-goal-trail" ref={trail}>
        <span className="acpmux-goal-actions">
          {canControl && !done && (
            <button
              type="button"
              className="acpmux-goal-action"
              disabled={pending}
              aria-label={live ? t("replay.pause") : t("composer.queueResume")}
              title={live ? t("replay.pause") : t("composer.queueResume")}
              onClick={() => void run(live ? "pause" : "resume")}
            >
              {live ? <PauseCircle size={16} /> : <PlayTriangle size={16} style={{ color: "inherit" }} />}
            </button>
          )}
          {canControl && (
            <button
              type="button"
              className="acpmux-goal-action"
              disabled={pending}
              aria-pressed={editing}
              aria-label={t("goal.edit")}
              title={t("goal.edit")}
              onClick={() => (editing ? cancel() : edit())}
            >
              <Pencil size={14} />
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
              <Close size={14} />
            </button>
          )}
        </span>
        <GoalTime goal={goal} live={live} />
        <span className="acpmux-goal-chevron" aria-hidden="true">
          <ChevronDown size={14} />
        </span>
      </span>
      {error && (
        <span className="acpmux-goal-error" role="alert">
          {error}
        </span>
      )}
    </section>
  );
}

/** Writes the trail's width (the time and chevron) on its row as `--acpmux-goal-trail` whenever its
 *  observer reports a change (after layout, before paint; no read of the page): the objective's first
 *  line stops short of it. Returns the cleanup. */
function keepTrailWidth(trail: HTMLElement | null | undefined) {
  const row = trail?.parentElement;
  if (!trail || !row || typeof ResizeObserver === "undefined") return;
  const observer = new ResizeObserver((entries) => {
    const size = entries.at(-1)?.borderBoxSize?.[0];
    if (!size) return;
    const width = `${size.inlineSize}px`;
    if (row.style.getPropertyValue("--acpmux-goal-trail") !== width)
      row.style.setProperty("--acpmux-goal-trail", width);
  });
  observer.observe(trail);
  return () => observer.disconnect();
}

/** The goal's elapsed time, a leaf of its own: the page clock's tick re-renders only this text, never
 *  the row, the hat or the composer around it. A `Clock` like the running lines' times, so its width
 *  changes only when a unit is added. */
function GoalTime({ goal, live }: { goal: TaskGoal; live: boolean }) {
  const current = useNow(live);
  const start = goal.startedAt;
  const elapsed =
    goal.elapsedMs !== undefined
      ? goal.elapsedMs + (live && goal.updatedAt !== undefined ? Math.max(0, current - goal.updatedAt) : 0)
      : start !== undefined
        ? Math.max(0, (goal.endedAt ?? (live ? current : (goal.updatedAt ?? current))) - start)
        : undefined;
  const text = elapsed === undefined ? undefined : formatDuration(elapsed);
  return text === undefined ? null : (
    <time className="acpmux-goal-time">
      <ClockText text={text} />
    </time>
  );
}
