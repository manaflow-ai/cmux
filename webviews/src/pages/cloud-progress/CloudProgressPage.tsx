// The Cloud progress page (cx-lu8f): a window's content while its Cloud machine is on its way to an
// open terminal (New Cloud Workspace, or a window on a paused machine's workspace). It shows the
// stage, the time so far and what happens next; a failure shows its reason with Retry, Copy Error and
// Dismiss, a paused machine Resume. The layout is the `cloud-progress-look` arm. Every element keeps
// its place across stages: the buttons and the typing note reserve their room while hidden, and only
// the marks and words change, so a failure or a pause moves nothing (Leo, 2026-11-04: "we move all
// our affected, possibly affected elements in the cohesive way").
import { useEffect, useState, useSyncExternalStore, type ReactNode } from "react";
import { experimentArm } from "../../experiments/experiment";
import { Button } from "../../ui/Button";
import { Disclosure } from "../../ui/Disclosure";
import { StatusGlyph } from "../../ui/StatusGlyph";
import type { StatusGlyphName } from "../../ui/statusGlyphs.generated";
import type { Strings } from "../shared/i18n";
import { cloudProgressLook } from "./cloudProgress.experiment";
import {
  elapsedClock,
  stageKey,
  stepMarks,
  type CloudProgressAction,
  type CloudProgressSnapshot,
  type CloudProgressStore,
  type StepMark,
} from "./store";
import type { CloudProgressState } from "./types";

export function CloudProgressPage({ store, strings }: { store: CloudProgressStore; strings: Strings }) {
  const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
  return (
    <CloudProgressView
      snapshot={snapshot}
      strings={strings}
      onAction={(action) => void store.run(action)}
      onAnswer={(id, accept) => void store.answer(id, accept)}
    />
  );
}

/** The status line's glyph: a paused machine is quiet grey (idle), never danger, accent or offline. */
function statusGlyph(stage: CloudProgressState["stage"]): StatusGlyphName {
  if (stage === "failed") return "error";
  if (stage === "ready") return "done";
  if (stage === "paused") return "idle";
  return "working";
}

const MARK_GLYPH: Record<StepMark, StatusGlyphName> = {
  done: "done",
  current: "working",
  failed: "error",
  next: "idle",
};

export function CloudProgressView({
  snapshot,
  strings,
  onAction,
  onAnswer,
}: {
  snapshot: CloudProgressSnapshot;
  strings: Strings;
  onAction: (action: CloudProgressAction) => void;
  /** Answers the open question (`state.ask`). */
  onAnswer: (id: string, accept: boolean) => void;
}) {
  const arm = experimentArm(cloudProgressLook);
  const state = snapshot.state;
  const elapsed = useElapsed(state, snapshot.receivedAt);
  const typed = useTypedNote(state, onAction, onAnswer);
  if (!state) return <div className="cloud-progress" data-look={arm} />;

  const { t, format } = strings;
  const failed = state.stage === "failed";
  const paused = state.stage === "paused";
  const marks = stepMarks(state);
  const title = state.machine ? format("cloudProgress.title.machine", state.machine) : t("cloudProgress.title.new");
  const stageWord = t(`cloudProgress.stage.${stageKey(state)}`);
  const ask = state.ask;
  // A question takes the detail's and the buttons' places: the page's blocks stay where they are.
  const detail = ask ? (
    <>
      <strong className="cloud-progress__ask-title">{ask.title}</strong>
      {"\n"}
      {ask.body}
    </>
  ) : state.failure ? (
    format("cloudProgress.failed", state.failure)
  ) : (
    t(`cloudProgress.next.${state.stage === "ready" ? "ready" : stageKey(state)}`)
  );
  const elapsedText = format("cloudProgress.elapsed", elapsedClock(elapsed));
  const stepLabels = state.steps.map((step) => t(`cloudProgress.stage.${step}`));

  const steps = (
    <ol className="cloud-progress__steps">
      {stepLabels.map((label, index) => (
        <li key={state.steps[index]} data-mark={marks[index]}>
          <StatusGlyph name={MARK_GLYPH[marks[index]!]} size={12} className="cloud-progress__mark" />
          <span>{label}</span>
        </li>
      ))}
    </ol>
  );
  const status = (
    // Only the stage word is live: the elapsed line ticks every second and would be read out each time.
    <span className="cloud-progress__status">
      <StatusGlyph name={statusGlyph(state.stage)} size={12} />
      <output className="cloud-progress__stage">{stageWord}</output>
      <span className="cloud-progress__elapsed">{elapsedText}</span>
    </span>
  );
  const shown = !!ask || failed || paused;
  const actions = (
    // Always laid out, hidden while there is nothing to do, so a failure or a question shifts nothing.
    <div
      className="cloud-progress__actions"
      data-shown={shown || undefined}
      data-ask={ask?.kind}
      aria-hidden={!shown}
      inert={!shown}
    >
      {ask ? (
        <>
          <Button variant="solid" onClick={() => onAnswer(ask.id, true)}>
            {ask.button}
          </Button>
          <Button onClick={() => onAnswer(ask.id, false)}>{ask.cancel}</Button>
        </>
      ) : (
        <>
          <Button variant="solid" onClick={() => onAction("retry")}>
            {t(paused ? "cloudProgress.button.resume" : "cloudProgress.button.retry")}
          </Button>
          {!paused && <Button onClick={() => onAction("copyError")}>{t("cloudProgress.button.copyError")}</Button>}
          <Button onClick={() => onAction("dismiss")}>{t("cloudProgress.button.dismiss")}</Button>
        </>
      )}
    </div>
  );
  const note = (
    <p className="cloud-progress__note" data-hidden={shown || undefined} data-typed={typed || undefined}>
      {t("cloudProgress.typing")}
    </p>
  );

  if (arm === "line") {
    // The status line opens the steps; a failure opens them, and what is under them moves down with
    // the panel's own height change.
    return (
      <div className="cloud-progress" data-look="line" data-stage={state.stage}>
        <h1 className="cloud-progress__title">{title}</h1>
        <LineSteps failed={failed} status={status}>
          {steps}
        </LineSteps>
        <p className="cloud-progress__detail selectable" data-ask={ask?.kind}>
          {detail}
        </p>
        {actions}
        {note}
      </div>
    );
  }
  if (arm === "card") {
    return (
      <div className="cloud-progress" data-look="card" data-stage={state.stage}>
        <div className="cloud-progress__card ui-card ui-glass">
          <h1 className="cloud-progress__title">{title}</h1>
          {status}
          <div className="cloud-progress__bar" role="presentation">
            {marks.map((mark, index) => (
              <span key={state.steps[index]} data-mark={mark} title={stepLabels[index]} />
            ))}
          </div>
          <p className="cloud-progress__detail selectable" data-ask={ask?.kind}>
            {detail}
          </p>
          {actions}
        </div>
        {note}
      </div>
    );
  }
  return (
    <div className="cloud-progress" data-look="steps" data-stage={state.stage}>
      <h1 className="cloud-progress__title">{title}</h1>
      <p className="cloud-progress__elapsed">{elapsedText}</p>
      {steps}
      <p className="cloud-progress__detail selectable" data-ask={ask?.kind}>
        {detail}
      </p>
      {actions}
      {note}
    </div>
  );
}

/** The `line` arm's steps behind its status line: closed while the machine is on its way, open once a step failed. */
function LineSteps({ failed, status, children }: { failed: boolean; status: ReactNode; children: ReactNode }) {
  const [open, setOpen] = useState(failed);
  useEffect(() => {
    if (failed) setOpen(true);
  }, [failed]);
  return (
    <Disclosure className="cloud-progress__disclosure" open={open} onOpenChange={setOpen} label={status}>
      {children}
    </Disclosure>
  );
}

/**
 * The time so far: the host's `elapsedMs` plus the time since it arrived, once a second while the
 * machine is on its way and the page is visible. It stops at ready, paused or failed, while the
 * page is hidden, and on unmount.
 */
function useElapsed(state: CloudProgressState | undefined, receivedAt: number): number {
  const [now, setNow] = useState(() => Date.now());
  const running = !!state && !state.finished;
  useEffect(() => {
    if (!running) return;
    let timer: ReturnType<typeof setInterval> | undefined;
    const follow = () => {
      clearInterval(timer);
      timer = undefined;
      if (document.visibilityState !== "visible") return;
      setNow(Date.now());
      timer = setInterval(() => setNow(Date.now()), 1000);
    };
    follow();
    document.addEventListener("visibilitychange", follow);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", follow);
    };
  }, [running]);
  if (!state) return 0;
  return running ? state.elapsedMs + Math.max(0, now - receivedAt) : state.elapsedMs;
}

/**
 * Keys typed before the terminal exists go nowhere: the note under the steps says so and turns to
 * the primary text color on the first key. While a question is open Return answers yes and Escape
 * no; while the buttons show Return is Retry (Resume).
 */
function useTypedNote(
  state: CloudProgressState | undefined,
  onAction: (action: CloudProgressAction) => void,
  onAnswer: (id: string, accept: boolean) => void,
) {
  const [typed, setTyped] = useState(false);
  const askID = state?.ask?.id;
  const shown = state?.stage === "failed" || state?.stage === "paused";
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.isComposing) return;
      const onButton = event.target instanceof HTMLButtonElement;
      if (askID) {
        if (event.key === "Enter" && !onButton) onAnswer(askID, true);
        else if (event.key === "Escape") onAnswer(askID, false);
        return;
      }
      if (shown) {
        if (event.key === "Enter" && !onButton) onAction("retry");
        return;
      }
      if (event.key.length === 1 || event.key === "Enter" || event.key === "Backspace") setTyped(true);
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [askID, shown, onAction, onAnswer]);
  return typed;
}
