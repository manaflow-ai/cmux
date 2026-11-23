import { useEffect, useState } from "react";
import { EnvironmentIcon } from "../EnvironmentPicker";
import { useT, type Translate } from "../i18n";
import {
  MOVE_STEPS,
  elapsedNow,
  landedOnFailure,
  moveActions,
  orderedCarries,
  runsAtName,
  seconds,
  stepKey,
  triggerKey,
  type MoveCarry,
  type MoveView,
} from "./placeModel";
import "./place.css";

/// How the move draws (MoveProgress.gallery.tsx compares them): `card`, a titled block with a step
/// bar and the carries; `line`, one row with the step, its clock and Cancel; `steps`, the eight
/// steps listed with the done ones ticked.
export type MoveProgressLook = "card" | "line" | "steps";

/// How long a finished move stays on screen before it goes.
const LIVE_LINGER_MS = 2500;

export function carryText(carry: MoveCarry, move: MoveView, t: Translate): string {
  switch (carry.kind) {
    case "history":
      return t("place.carry.history");
    case "turn":
      return carry.how === "interrupted"
        ? t("place.carry.turnInterrupted")
        : t("place.carry.turnContinues", { to: move.to });
    case "queue":
      return t("place.carry.queue", { n: carry.count ?? 0 });
    case "draft":
      return t("place.carry.draft");
    case "branch":
      return carry.name ? t("place.carry.branch", { name: carry.name }) : t("place.carry.branchPlain");
    case "changes":
      return t("place.carry.changes", { n: carry.count ?? 0 });
  }
}

/// The page's own clock for a running move, one tick per 100 ms; stopped once it ends.
export function useNow(running: boolean, fixed: number | undefined): number {
  const [now, setNow] = useState(() => fixed ?? Date.now());
  useEffect(() => {
    if (!running || fixed !== undefined) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 100);
    return () => clearInterval(timer);
  }, [running, fixed]);
  return fixed ?? now;
}

/// What moves with the chat. A move that failed or was cancelled carries nothing: the chat stays
/// where it was, so the list would contradict "Still running on ...".
function Carries({ move, t }: { move: MoveView; t: Translate }) {
  if (move.state === "failed" || move.state === "cancelled") return null;
  const list = orderedCarries(move);
  if (list.length === 0) return null;
  return (
    <ul className="acpmux-move-carries" aria-label={t("place.move.carries")}>
      {list.map((carry) => (
        <li key={carry.kind} data-how={carry.how}>
          {carryText(carry, move, t)}
        </li>
      ))}
    </ul>
  );
}

/// The one line that says what the person can do or what happened, by state.
function Status({ move, t, waitingOn }: { move: MoveView; t: Translate; waitingOn: string }) {
  if (move.state === "failed") {
    return (
      <>
        {move.reason && <p className="acpmux-move-reason">{move.reason}</p>}
        <p className="acpmux-move-note">
          {landedOnFailure(move)
            ? t("place.move.landed", { place: runsAtName(move) })
            : t("place.move.stillRunning", { place: runsAtName(move) })}
        </p>
      </>
    );
  }
  if (move.state === "cancelled") {
    return <p className="acpmux-move-note">{t("place.move.stillRunning", { place: runsAtName(move) })}</p>;
  }
  if (move.state === "live") return <p className="acpmux-move-note">{t("place.move.live", { to: move.to })}</p>;
  if (move.finishing) return <p className="acpmux-move-note">{t("place.move.finishing")}</p>;
  if (move.overBudget) {
    return (
      <p className="acpmux-move-note" data-over="true">
        {t("place.move.over", { budget: seconds(move.budgetMs), step: waitingOn })}
      </p>
    );
  }
  return null;
}

/// A chat's move, drawn from `place.move`: the labelled step, step i of 8, the clock against the
/// 10 s bound, what moves with it, Cancel while it can be, and how it ended. The webview only ticks
/// the clock; every decision is the app's. A finished move shows briefly and goes (`linger`).
export function MoveProgress({
  move,
  look = "card",
  onCancel,
  onRetry,
  now: fixedNow,
  linger = LIVE_LINGER_MS,
}: {
  move: MoveView;
  look?: MoveProgressLook;
  onCancel(): void;
  onRetry(): void;
  /// Gallery and tests: the clock, so a fixture reads the same on every run.
  now?: number;
  /// How long a finished (live) move stays; Infinity keeps it.
  linger?: number;
}) {
  const t = useT();
  const running = move.state === "moving";
  const clock = useNow(running, fixedNow);
  const [gone, setGone] = useState(false);
  useEffect(() => {
    setGone(false);
    if (move.state !== "live" || !Number.isFinite(linger)) return;
    const timer = setTimeout(() => setGone(true), linger);
    return () => clearTimeout(timer);
  }, [move.state, move.startedMs, linger]);
  if (gone) return null;
  const actions = moveActions(move);
  const stepLabel = t(stepKey(move.step, move.direction));
  const why = triggerKey(move.trigger);
  const elapsed = seconds(elapsedNow(move, clock));
  const budget = seconds(move.budgetMs);
  const ended = move.state === "failed" || move.state === "cancelled";
  const title =
    move.state === "failed"
      ? t("place.move.failed")
      : move.state === "cancelled"
        ? t("place.move.cancelled")
        : move.state === "live"
          ? t("place.move.live", { to: move.to })
          : t("place.move.title", { to: move.to });
  const counter = t("place.move.stepOf", { i: move.stepIndex + 1, n: move.stepCount });
  const time = t("place.move.time", { elapsed, budget });
  const controls = (
    <>
      {actions.cancel && (
        <button type="button" className="acpmux-move-btn" data-testid="move-cancel" onClick={onCancel}>
          {t("place.move.cancel")}
        </button>
      )}
      {actions.retry && (
        <button
          type="button"
          className="acpmux-move-btn"
          data-primary="true"
          data-testid="move-retry"
          onClick={onRetry}
        >
          {t("place.move.retry")}
        </button>
      )}
    </>
  );
  // The turn that will not survive the move is said before the freeze (while moving, up to it).
  const warn = running && move.interruptsTurn;
  const bar = (
    <div
      className="acpmux-move-bar"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a segmented step bar, one segment per step state, which <progress> cannot draw
      role="progressbar"
      aria-label={t("place.move.label")}
      aria-valuemin={1}
      aria-valuemax={move.stepCount}
      aria-valuenow={move.stepIndex + 1}
      aria-valuetext={`${counter}: ${stepLabel}`}
    >
      {MOVE_STEPS.slice(0, move.stepCount).map((step, index) => (
        <span
          key={step}
          data-state={
            index < move.stepIndex ? "done" : index === move.stepIndex ? (ended ? "stopped" : "current") : "todo"
          }
        />
      ))}
    </div>
  );
  const root = {
    className: "acpmux-move",
    "data-look": look,
    "data-state": move.state,
    "data-over": running && move.overBudget ? "true" : undefined,
    "data-warn": warn ? "true" : undefined,
    "aria-label": t("place.move.label"),
  } as const;
  if (look === "line") {
    return (
      <section {...root}>
        <div className="acpmux-move-line">
          <span className="acpmux-move-dot" data-state={move.state} aria-hidden="true" />
          <span className="acpmux-move-step">{ended || move.state === "live" ? title : stepLabel}</span>
          {running && <span className="acpmux-move-count">{counter}</span>}
          <span className="acpmux-move-clock">{time}</span>
          {controls}
        </div>
        {warn && <p className="acpmux-move-warn">{t("place.carry.turnInterrupted")}</p>}
        <Status move={move} t={t} waitingOn={stepLabel} />
      </section>
    );
  }
  if (look === "steps") {
    return (
      <section {...root}>
        <header className="acpmux-move-head">
          <span className="acpmux-move-title">{title}</span>
          <span className="acpmux-move-clock">{time}</span>
          {controls}
        </header>
        {why && running && <p className="acpmux-move-note">{t(why)}</p>}
        <ol className="acpmux-move-steps">
          {MOVE_STEPS.map((step, index) => (
            <li
              key={step}
              data-state={
                move.state === "live" || index < move.stepIndex
                  ? "done"
                  : index === move.stepIndex
                    ? ended
                      ? "stopped"
                      : "current"
                    : "todo"
              }
            >
              <span className="acpmux-move-mark" aria-hidden="true" />
              {t(stepKey(step, move.direction))}
            </li>
          ))}
        </ol>
        <Carries move={move} t={t} />
        <Status move={move} t={t} waitingOn={stepLabel} />
      </section>
    );
  }
  return (
    <section {...root}>
      <header className="acpmux-move-head">
        <span className="acpmux-move-icon">
          <EnvironmentIcon kind={move.direction === "toCloud" ? "cloud" : "local"} />
        </span>
        <span className="acpmux-move-title">{title}</span>
        <span className="acpmux-move-clock">{time}</span>
      </header>
      {why && running && <p className="acpmux-move-note">{t(why)}</p>}
      {bar}
      {running && (
        <p className="acpmux-move-stepline">
          <span className="acpmux-move-step">{stepLabel}</span>
          <span className="acpmux-move-count">{counter}</span>
        </p>
      )}
      <Carries move={move} t={t} />
      <Status move={move} t={t} waitingOn={stepLabel} />
      {(actions.cancel || actions.retry) && <div className="acpmux-move-actions">{controls}</div>}
    </section>
  );
}
