// l10n-allow-file: gallery prototype (sample transcript), not shipped UI.
// Thinking and steps, minimized by default: a turn at work shows one shimmering line (the current
// step's title, or "Thinking"). A tap opens the details: in a column to the right of the
// transcript, in place below the line, in a small card, or as a step rail in the turn's gutter.
// A finished turn keeps one quiet line ("Thought for 41s · 9 steps") only when Steps is on.
import { useState } from "react";
import { Chevron, GlassCircle, MacWindow, Phone, SessionList, Shimmer, StatusMark, type Platform } from "./parts";
import "./subagents.css";

export type ThinkingDesign = "side" | "inline" | "card" | "rail";

export type ThinkingStepsProps = {
  platform: Platform;
  design: ThinkingDesign;
  /** The details are open (what a tap on the shimmer shows). */
  expanded?: boolean;
  /** The Steps setting: off (default) hides the finished turn's steps line. */
  steps?: boolean;
  /** `working`: the turn is thinking or running a tool; `finished`: it has answered. */
  phase?: "working" | "finished";
  /** What the shimmer says: the current step's title, or the plain word. */
  label?: "step" | "thinking";
};

type Step = { title: string; kind: "thought" | "tool"; detail: string; seconds: number; state: "done" | "running" };

const STEPS: Step[] = [
  {
    title: "Reading the outbox code",
    kind: "tool",
    detail: "Read Sources/Sync/OutboxStore.swift (412 lines)",
    seconds: 2,
    state: "done",
  },
  {
    title: "Considering where to persist",
    kind: "thought",
    detail:
      "The outbox lives only in memory today. SQLite is already linked for drafts, so a table there avoids a second store. Ordering must survive a crash: use a monotonic sequence column, not timestamps.",
    seconds: 6,
    state: "done",
  },
  { title: "Searching for enqueue( call sites", kind: "tool", detail: "31 hits in 9 files", seconds: 1, state: "done" },
  {
    title: "Checking the reconnect path",
    kind: "thought",
    detail: "Reconnect calls flush() before the socket is authenticated; replay must wait for the auth event.",
    seconds: 9,
    state: "done",
  },
  { title: "Editing OutboxStore.swift", kind: "tool", detail: "+84 −12", seconds: 4, state: "done" },
  { title: "Running swift test --filter Outbox", kind: "tool", detail: "14 passed", seconds: 11, state: "done" },
  {
    title: "Planning the conflict rules",
    kind: "thought",
    detail: "Last writer wins per field; deletes win over edits.",
    seconds: 5,
    state: "running",
  },
];

export function ThinkingSteps({
  platform,
  design,
  expanded = false,
  steps = false,
  phase = "working",
  label = "step",
}: ThinkingStepsProps) {
  const [open, setOpen] = useState(expanded);
  const [stepsOn, setStepsOn] = useState(steps);
  const visible = phase === "working" ? STEPS : STEPS.map((step) => ({ ...step, state: "done" as const }));
  const current = visible.find((step) => step.state === "running");
  const total = visible.reduce((sum, step) => sum + step.seconds, 0);
  const shimmerText = label === "thinking" || !current ? "Thinking" : current.title;
  const line =
    phase === "working" ? (
      <button type="button" className="sa-think-line" aria-expanded={open} onClick={() => setOpen((value) => !value)}>
        <Shimmer>{shimmerText}</Shimmer>
        <span className="sa-muted">{total}s</span>
      </button>
    ) : stepsOn ? (
      <button
        type="button"
        className="sa-think-line sa-think-done"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <span>
          Thought for {total}s · {visible.length} steps
        </span>
        <Chevron open={open && design !== "side"} />
      </button>
    ) : null;
  const details = <StepList steps={visible} />;
  const turn = (
    <div className="sa-turn" data-design={design} data-open={open || undefined}>
      {design === "rail" && (phase === "working" || stepsOn) && (
        <div className="sa-rail-steps" aria-label="Steps">
          {visible.map((step) => (
            <button
              key={step.title}
              type="button"
              className="sa-rail-step"
              data-state={step.state}
              data-kind={step.kind}
              title={step.title}
              aria-label={step.title}
              onClick={() => setOpen(true)}
            />
          ))}
        </div>
      )}
      <div className="sa-turn-body">
        <div className="sa-bubble sa-bubble-user">Make the outbox survive a restart, and replay it on reconnect.</div>
        {line}
        {open && design === "inline" && <div className="sa-think-inline">{details}</div>}
        {open && design === "card" && (
          <div className="sa-think-card">
            {details}
            <button type="button" className="sa-text-button" onClick={() => setOpen(false)}>
              Close
            </button>
          </div>
        )}
        {open && design === "rail" && <div className="sa-think-inline">{details}</div>}
        {phase === "finished" && (
          <p className="sa-prose">
            The outbox is now a SQLite table with a sequence column, so a crash keeps its order. Reconnect waits for the
            auth event before it replays. 14 tests pass.
          </p>
        )}
      </div>
    </div>
  );
  const settingsToggle = (
    <button
      type="button"
      className="sa-toggle"
      aria-pressed={stepsOn}
      // tooltip-allow: carries the ⌥⌘T shortcut.
      title="Show steps (⌥⌘T)"
      onClick={() => setStepsOn((value) => !value)}
    >
      Steps
    </button>
  );

  if (platform === "iphone") {
    const sheet = open && design === "side";
    return (
      <Phone
        toolbar={
          <>
            <GlassCircle glyph="back" label="Back" />
            <span className="sa-phone-title">
              <strong>Ship offline sync</strong>
              <span className="sa-muted">Claude · cnx-ios</span>
            </span>
            <GlassCircle glyph="more" label="More" />
          </>
        }
        bottom={
          <div className="sa-phone-composer">
            <span className="sa-muted">Follow up</span>
            {settingsToggle}
            <span className="sa-send" data-stop={phase === "working" || undefined} aria-hidden="true" />
          </div>
        }
        overlay={
          sheet && (
            <div className="sa-phone-sheet" aria-label="Steps">
              <div className="sa-sheet-grabber" aria-hidden="true" />
              <header className="sa-sheet-header">
                <strong>Steps</strong>
                <span className="sa-muted">
                  {visible.length} · {total}s
                </span>
                <span className="sa-spacer" />
                <button type="button" className="sa-text-button" onClick={() => setOpen(false)}>
                  Done
                </button>
              </header>
              {details}
            </div>
          )
        }
      >
        <div className="sa-chat" data-platform="iphone">
          {turn}
        </div>
      </Phone>
    );
  }
  return (
    <MacWindow title="cnx-ios" sidebarWidth={220} sidebar={<SessionList />}>
      <div className="sa-split" data-open={(open && design === "side") || undefined}>
        <div className="sa-chat" data-platform="mac">
          <div className="sa-chat-toolbar">{settingsToggle}</div>
          {turn}
        </div>
        {open && design === "side" && (
          <aside className="sa-think-side" aria-label="Steps">
            <header className="sa-sheet-header">
              <strong>Steps</strong>
              <span className="sa-muted">
                {visible.length} · {total}s
              </span>
              <span className="sa-spacer" />
              <button type="button" className="sa-text-button" onClick={() => setOpen(false)}>
                Close
              </button>
            </header>
            {details}
          </aside>
        )}
      </div>
    </MacWindow>
  );
}

function StepList({ steps }: { steps: Step[] }) {
  return (
    <ol className="sa-steps">
      {steps.map((step) => (
        <li key={step.title} data-kind={step.kind} data-state={step.state}>
          <span className="sa-step-mark">
            {step.state === "running" ? (
              <StatusMark state="running" />
            ) : (
              <span className="sa-step-dot" data-kind={step.kind} />
            )}
          </span>
          <span className="sa-step-text">
            <span className="sa-step-title">
              {step.state === "running" ? <Shimmer>{step.title}</Shimmer> : step.title}
            </span>
            <span className="sa-step-detail" data-kind={step.kind}>
              {step.detail}
            </span>
          </span>
          <span className="sa-muted">{step.seconds}s</span>
        </li>
      ))}
    </ol>
  );
}
