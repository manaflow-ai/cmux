// l10n-allow-file: gallery fixture (sample workflow phases, agents and token counts), not shipped UI.
//
// A Claude-style dynamic workflow board for capture review. It is intentionally a gallery-only
// surface: the pause, stop and save controls update local labels and never touch an acpmux session.
import { useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

type Surface = "inline-latest" | "pinned-summary";
type Mode = "light" | "dark";
type WorkflowState = "Running" | "Paused" | "Stopped" | "Saved";

type Props = {
  surface: Surface;
  mode: Mode;
};

type Phase = {
  id: string;
  name: string;
  done: number;
  total: number;
  model: string;
  elapsed: string;
};

const WORKFLOW = {
  title: "Refresh release notes across the workspace",
  warning: "Large workflow · 101 agents can run in parallel",
  done: 37,
  total: 101,
  elapsed: "08:42",
  tokens: "1.2M / 2.0M",
  sparkline: [8, 12, 10, 18, 16, 26, 24, 35, 31, 39, 37],
  phases: [
    { id: "discover", name: "Discover", done: 14, total: 14, model: "Claude Sonnet 4.5", elapsed: "01:26" },
    { id: "implement", name: "Implement", done: 16, total: 48, model: "Claude Opus 4.1", elapsed: "05:11" },
    { id: "review", name: "Review", done: 7, total: 24, model: "Claude Sonnet 4.5", elapsed: "02:05" },
    { id: "integrate", name: "Integrate", done: 0, total: 15, model: "Claude Haiku 4.5", elapsed: "—" },
  ] satisfies Phase[],
};

const SELECTED_AGENTS = [
  { name: "release-notes-17", task: "Compare highlights with the changelog", state: "done", model: "Opus 4.1" },
  { name: "release-notes-18", task: "Rewrite the migration note", state: "running", model: "Opus 4.1" },
  { name: "release-notes-19", task: "Check links and headings", state: "running", model: "Sonnet 4.5" },
  { name: "release-notes-20", task: "Check locale parity", state: "queued", model: "Haiku 4.5" },
];

function ProgressSparkline() {
  const points = WORKFLOW.sparkline.map((value, index) => `${index * 10},${42 - value}`).join(" ");
  return (
    <svg
      className="workflow-gallery__sparkline"
      viewBox="0 0 100 44"
      role="img"
      aria-label="Workflow progress sparkline"
    >
      <polyline points={points} pathLength="1" />
      <circle cx="100" cy={42 - WORKFLOW.sparkline.at(-1)!} r="2.5" />
    </svg>
  );
}

function WorkflowControls() {
  const [state, setState] = useState<WorkflowState>("Running");
  return (
    <div className="workflow-gallery__controls" data-workflow-state={state.toLowerCase()}>
      <span className="workflow-gallery__state" aria-live="polite">
        {state}
      </span>
      <button type="button" onClick={() => setState("Paused")} aria-label="Pause workflow">
        Pause
      </button>
      <button type="button" onClick={() => setState("Stopped")} aria-label="Stop workflow">
        Stop
      </button>
      <button type="button" onClick={() => setState("Saved")} aria-label="Save workflow">
        Save
      </button>
    </div>
  );
}

function WorkflowSummary({ compact = false }: { compact?: boolean }) {
  return (
    <div
      className={`workflow-gallery__summary${compact ? " workflow-gallery__summary--compact" : ""}`}
      data-workflow-summary
    >
      <div className="workflow-gallery__summary-head">
        <div>
          <span className="workflow-gallery__kicker">Dynamic workflow</span>
          <strong>{WORKFLOW.title}</strong>
        </div>
        <span className="workflow-gallery__warning">{WORKFLOW.warning}</span>
      </div>
      <div className="workflow-gallery__summary-grid">
        <div>
          <span className="workflow-gallery__metric-label">Agents</span>
          <strong>
            {WORKFLOW.done} / {WORKFLOW.total} done
          </strong>
        </div>
        <div>
          <span className="workflow-gallery__metric-label">Elapsed</span>
          <strong>{WORKFLOW.elapsed}</strong>
        </div>
        <div>
          <span className="workflow-gallery__metric-label">Tokens</span>
          <strong>{WORKFLOW.tokens}</strong>
        </div>
        <ProgressSparkline />
      </div>
      <div
        className="workflow-gallery__progress"
        role="progressbar"
        aria-label="Workflow agents done"
        aria-valuenow={WORKFLOW.done}
        aria-valuemin={0}
        aria-valuemax={WORKFLOW.total}
      >
        <span style={{ width: `${(WORKFLOW.done / WORKFLOW.total) * 100}%` }} />
      </div>
      <div className="workflow-gallery__phase-counts">
        {WORKFLOW.phases.map((phase) => (
          <span key={phase.id}>
            <b>
              {phase.done}/{phase.total}
            </b>{" "}
            {phase.name} · {phase.model}
          </span>
        ))}
      </div>
      {!compact && <WorkflowControls />}
    </div>
  );
}

function InlineLatest() {
  return (
    <div className="workflow-gallery__surface" data-workflow-surface="inline-latest">
      <div className="workflow-gallery__transcript">
        <span className="workflow-gallery__kicker">Agent chat</span>
        <p className="workflow-gallery__message workflow-gallery__message--user">
          Update the release notes for every changed package.
        </p>
        <p className="workflow-gallery__message">
          I started a dynamic workflow. The summary stays after my latest message while the agents fan out.
        </p>
      </div>
      <div className="workflow-gallery__latest-label">Latest message · workflow in progress</div>
      <WorkflowSummary />
    </div>
  );
}

function PinnedSummary() {
  return (
    <div className="workflow-gallery__surface" data-workflow-surface="pinned-summary">
      <div className="workflow-gallery__pinned-stage">
        <div className="workflow-gallery__pinned-scroll" data-pinned-transcript>
          <div className="workflow-gallery__pinned-summary" data-pinned-summary>
            <div className="workflow-gallery__pin-line">
              <span className="workflow-gallery__pin-dot" aria-hidden="true" />
              <span>Pinned workflow</span>
              <span className="workflow-gallery__pin-rule" />
              <span>sticky while the transcript scrolls</span>
            </div>
            <WorkflowSummary />
          </div>
          <div className="workflow-gallery__pinned-copy">
            <span className="workflow-gallery__kicker">Agent chat transcript</span>
            <p>37 agents finished their pass. The pinned summary remains in view as this transcript grows.</p>
            <p>Review is waiting on the remaining Implement agents before Integrate can begin.</p>
            <p>Keep chatting below while the workflow continues in the background.</p>
          </div>
        </div>
      </div>
      <div className="workflow-gallery__pinned-footer">
        Select the workflow for phase detail or keep chatting below.
      </div>
    </div>
  );
}

function DynamicWorkflowGallery({ surface, mode }: Props) {
  return (
    <div className="workflow-gallery" data-workflow-gallery data-mode={mode}>
      {surface === "inline-latest" && <InlineLatest />}
      {surface === "pinned-summary" && <PinnedSummary />}
    </div>
  );
}

const paired = (surface: Surface, note: string, play?: Play): Record<string, ComponentVariant<Props>> => ({
  [`${surface}-light`]: {
    note: `${note} Light theme keeps the warning and completion counts legible at a glance.`,
    props: { surface, mode: "light" },
    ...(play ? { play } : {}),
  },
  [`${surface}-dark`]: {
    note: `${note} Dark theme keeps the warning, sparkline and phase state distinct without extra glow.`,
    props: { surface, mode: "dark" },
    ...(play ? { play } : {}),
  },
});

export default componentEntry<Props>({
  id: "agent-pane.dynamic-workflow",
  title: "Dynamic workflow placements",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 760,
  widths: { narrow: 440, normal: 780, wide: 1100 },
  anchors: [{ selector: "[data-workflow-gallery]" }],
  covers: ["agent-session/acpmux/conversation/BackgroundTaskNote.tsx#BackgroundTaskNote"],
  styles: () => import("./DynamicWorkflow.gallery.css"),
  load: async () => DynamicWorkflowGallery,
  variants: {
    ...paired(
      "inline-latest",
      "An inline summary row follows the latest assistant message with a large-workflow warning, 37/101 agents done, elapsed time, token budget, progress sparkline, phase counts and model labels.",
    ),
    ...paired(
      "pinned-summary",
      "A pinned summary row stays visible above the transcript and exposes the same warning, progress and pause/stop/save affordances.",
    ),
  },
});
