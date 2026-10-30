// l10n-allow-file: gallery fixture (sample workflow phases, agents and token counts), not shipped UI.
//
// A Claude-style dynamic workflow board for capture review. It is intentionally a gallery-only
// surface: the pause, stop and save controls update local labels and never touch an acpmux session.
import { useState, type KeyboardEvent } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";

type Surface = "inline-latest" | "pinned-summary" | "detail-sheet";
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

const AGENT_TASKS = [
  { task: "Compare highlights with the changelog", state: "done" },
  { task: "Rewrite the migration note", state: "running" },
  { task: "Check links and headings", state: "running" },
  { task: "Check locale parity", state: "queued" },
] as const;

function agentsFor(phase: Phase) {
  const doneCount =
    phase.total === 0 ? 0 : Math.min(AGENT_TASKS.length, Math.floor((phase.done / phase.total) * AGENT_TASKS.length));
  const runningIndex = phase.done > 0 && phase.done < phase.total ? doneCount : -1;
  return AGENT_TASKS.map((agent, index) => ({
    name: `${phase.id}-${17 + index}`,
    task: agent.task,
    state: index < doneCount ? "done" : index === runningIndex ? "running" : "queued",
    model: phase.model.replace("Claude ", ""),
  }));
}

function ProgressSparkline() {
  const points = WORKFLOW.sparkline.map((value, index) => `${index * 10},${42 - value}`).join(" ");
  return (
    <svg
      className="workflow-gallery__sparkline"
      viewBox="0 0 100 44"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the geometry below is built from the workflow's own numbers; an <img> would need it serialized first and could not update it.
      role="img"
      aria-label="Workflow progress sparkline"
    >
      <polyline points={points} pathLength="1" />
      <circle cx="100" cy={42 - WORKFLOW.sparkline.at(-1)!} r="2.5" />
    </svg>
  );
}

function WorkflowControls({
  state,
  onStateChange,
  announce = true,
}: {
  state: WorkflowState;
  onStateChange: (state: WorkflowState) => void;
  announce?: boolean;
}) {
  return (
    <div className="workflow-gallery__controls" data-workflow-state={state.toLowerCase()}>
      <span className="workflow-gallery__state" aria-live={announce ? "polite" : undefined}>
        {state}
      </span>
      <button type="button" onClick={() => onStateChange("Paused")} aria-label="Pause workflow">
        Pause
      </button>
      <button type="button" onClick={() => onStateChange("Stopped")} aria-label="Stop workflow">
        Stop
      </button>
      <button type="button" onClick={() => onStateChange("Saved")} aria-label="Save workflow">
        Save
      </button>
    </div>
  );
}

function WorkflowSummary({ compact = false }: { compact?: boolean }) {
  const [state, setState] = useState<WorkflowState>("Running");
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
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a styled bar; <progress> cannot take the fill span.
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
      {!compact && <WorkflowControls state={state} onStateChange={setState} />}
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
        Compare with the separate workflow-detail proposal, or keep chatting below.
      </div>
    </div>
  );
}

function PhaseList({ selected, onSelect }: { selected: string; onSelect: (id: string) => void }) {
  return (
    <nav className="workflow-gallery__phases" aria-label="Workflow phases">
      <span className="workflow-gallery__kicker">Phases</span>
      {WORKFLOW.phases.map((phase) => (
        <button
          type="button"
          key={phase.id}
          data-phase={phase.id}
          className={selected === phase.id ? "is-selected" : undefined}
          aria-pressed={selected === phase.id}
          onClick={() => onSelect(phase.id)}
        >
          <span>
            <strong>{phase.name}</strong>
            <small>{phase.model}</small>
          </span>
          <b>
            {phase.done}/{phase.total}
          </b>
        </button>
      ))}
    </nav>
  );
}

function SelectedPhase({
  phase,
  state,
  onStateChange,
}: {
  phase: Phase;
  state: WorkflowState;
  onStateChange: (state: WorkflowState) => void;
}) {
  return (
    <section className="workflow-gallery__selected-phase" data-selected-phase={phase.id}>
      <div className="workflow-gallery__selected-head">
        <div>
          <span className="workflow-gallery__kicker">Selected phase</span>
          <h2>{phase.name}</h2>
          <p>
            {phase.done} of {phase.total} agents done · {phase.elapsed} elapsed · {phase.model}
          </p>
        </div>
        <span className="workflow-gallery__phase-badge">{Math.round((phase.done / phase.total) * 100)}%</span>
      </div>
      <div className="workflow-gallery__agents">
        {agentsFor(phase).map((agent) => (
          <div className="workflow-gallery__agent" data-agent-state={agent.state} key={agent.name}>
            <span className="workflow-gallery__agent-mark" aria-hidden="true" />
            <span>
              <strong>{agent.name}</strong>
              <small>{agent.task}</small>
            </span>
            <span className="workflow-gallery__agent-model">{agent.model}</span>
            <span className="workflow-gallery__agent-state">{agent.state}</span>
          </div>
        ))}
      </div>
      <WorkflowControls state={state} onStateChange={onStateChange} announce={false} />
    </section>
  );
}

function DetailSheet() {
  const [selected, setSelected] = useState("implement");
  const [tab, setTab] = useState<"workflow" | "transcript">("workflow");
  const [workflowState, setWorkflowState] = useState<WorkflowState>("Running");
  const selectTab = (next: "workflow" | "transcript") => {
    setTab(next);
    document.getElementById(`workflow-${next}-tab`)?.focus();
  };
  const onTabKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const order = ["workflow", "transcript"] as const;
    const current = order.indexOf(tab);
    const direction = getComputedStyle(event.currentTarget).direction === "rtl" ? -1 : 1;
    let next = current;
    if (event.key === "Home") next = 0;
    else if (event.key === "End") next = order.length - 1;
    else if (event.key === "ArrowRight") next = (current + direction + order.length) % order.length;
    else if (event.key === "ArrowLeft") next = (current - direction + order.length) % order.length;
    else return;
    event.preventDefault();
    selectTab(order[next]!);
  };
  const phase = WORKFLOW.phases.find((candidate) => candidate.id === selected) ?? WORKFLOW.phases[1]!;
  return (
    <div className="workflow-gallery__sheet" data-workflow-surface="detail-sheet">
      <header className="workflow-gallery__sheet-header">
        <div>
          <span className="workflow-gallery__kicker">Workflow detail</span>
          <h2>{WORKFLOW.title}</h2>
        </div>
        <WorkflowControls state={workflowState} onStateChange={setWorkflowState} />
      </header>
      {/* A roving tabindex: the tabs below take the focus and the list only routes their arrow
          keys, so making the list itself focusable would add a tab stop ARIA does not want. */}
      {/* oxlint-disable-next-line jsx-a11y/interactive-supports-focus */}
      <div className="workflow-gallery__tabs" role="tablist" aria-label="Workflow detail tabs" onKeyDown={onTabKeyDown}>
        <button
          id="workflow-workflow-tab"
          type="button"
          role="tab"
          aria-selected={tab === "workflow"}
          aria-controls="workflow-workflow-panel"
          tabIndex={tab === "workflow" ? 0 : -1}
          onClick={() => selectTab("workflow")}
        >
          Workflow
        </button>
        <button
          id="workflow-transcript-tab"
          type="button"
          role="tab"
          aria-selected={tab === "transcript"}
          aria-controls="workflow-transcript-panel"
          tabIndex={tab === "transcript" ? 0 : -1}
          onClick={() => selectTab("transcript")}
        >
          Transcript
        </button>
      </div>
      <div
        id="workflow-workflow-panel"
        className="workflow-gallery__detail-grid"
        role="tabpanel"
        aria-labelledby="workflow-workflow-tab"
        tabIndex={0}
        hidden={tab !== "workflow"}
      >
        <PhaseList selected={selected} onSelect={setSelected} />
        <SelectedPhase phase={phase} state={workflowState} onStateChange={setWorkflowState} />
      </div>
      <div
        id="workflow-transcript-panel"
        className="workflow-gallery__transcript-tab"
        role="tabpanel"
        aria-labelledby="workflow-transcript-tab"
        tabIndex={0}
        hidden={tab !== "transcript"}
      >
        <span className="workflow-gallery__kicker">Latest activity</span>
        <p>37 agents finished their pass. 64 remain in Implement, Review and Integrate.</p>
        <WorkflowSummary compact />
      </div>
    </div>
  );
}

function DynamicWorkflowGallery({ surface, mode }: Props) {
  return (
    <div className="workflow-gallery" data-workflow-gallery data-mode={mode}>
      {surface === "inline-latest" && <InlineLatest />}
      {surface === "pinned-summary" && <PinnedSummary />}
      {surface === "detail-sheet" && <DetailSheet />}
    </div>
  );
}

const inspectPhase: Play = async (ctx) => {
  await ctx.click({ selector: '[data-phase="review"]' });
  await ctx.waitFor(() => ctx.document.querySelector('[data-selected-phase="review"]'));
};

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
    ...paired(
      "detail-sheet",
      "A detail sheet/tab puts phases on the left and selected-phase agents on the right, including per-phase counts, models, elapsed time and controls.",
      inspectPhase,
    ),
  },
});
