// l10n-allow-file: gallery fixture (sample workflow, phase and agent names), not shipped UI.
// A Claude workflow's card in the transcript (Labs `workflowLabs`, WorkflowCard.tsx), drawn from a
// workflow's events fed through the real subagent fold (workflowFixture.ts): its name, "Workflow ·
// N agents · time" and a dot per agent, live while it runs. A click opens Session Info's
// Background tasks (session-info/WorkflowTasks.tsx), whose gallery is agent-pane.chat-inspector.
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { realWorkflowFixture } from "../realWorkflowFixture";
import {
  configureWorkflowCardOpen,
  configureWorkflowCardSideTab,
  WorkflowCard,
  type WorkflowCardPresentation,
} from "./WorkflowCard";
import { workflowFixture, type WorkflowFixtureStage } from "./workflowFixture";

type Props = {
  stage: WorkflowFixtureStage;
  presentation: WorkflowCardPresentation;
  replay?: ReturnType<typeof realWorkflowFixture>;
};

/// The gallery's cards open nothing, but draw as the chat's do: a button.
configureWorkflowCardOpen(() => undefined);
configureWorkflowCardSideTab(() => undefined);

function GalleryWorkflowCard({ stage, presentation, replay }: Props) {
  const nodes = (replay ?? workflowFixture(stage)).filter((node) => node.kind === "workflow");
  return (
    <div className="acpmux-shell" style={{ padding: "16px 20px" }}>
      {nodes.map((node) => (
        <WorkflowCard key={node.id} node={node} presentation={presentation} />
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.workflow-card",
  title: "Workflow card",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/summary/WorkflowCard.tsx",
    "agent-session/acpmux/summary/workflowDots.css",
    "agent-session/acpmux/subagents/runningTray.ts",
  ],
  load: async () => GalleryWorkflowCard,
  variants: {
    "selected-running": {
      note: "Selected treatment: title and state, N/M progress, current phase with model and elapsed time, latest agent line, and known tokens. Before: dots only. After: the card explains what the workflow is doing without opening Session Info.",
      props: { stage: "running", presentation: "selected" },
    },
    "compact-running": {
      note: "Gallery alternative A: a single metadata line with a thin N/M progress bar. It keeps the card shortest while the selected treatment remains the shipped design.",
      props: { stage: "running", presentation: "compact" },
    },
    "phases-running": {
      note: "Gallery alternative B: the current phase remains in metadata and each phase gets a status strip. It makes the workflow topology visible at a glance; the selected treatment remains the shipped design.",
      props: { stage: "running", presentation: "phases" },
    },
    "selected-finished": {
      note: "Selected treatment after completion: 7/7, completed state, final elapsed time and total tokens remain visible; the progress bar is full and no done line repeats the card.",
      props: { stage: "finished", presentation: "selected" },
    },
    "real-run": {
      note: "Labs: a scrubbed card replayed from a real Claude Workflow stream. Completed, Report, 3/3 and 10s, with the recorded tokens and model.",
      props: { stage: "finished", presentation: "selected", replay: realWorkflowFixture(GALLERY_NOW) },
    },
    "real-running": {
      note: "Labs: the real Claude Workflow replay while it runs. Report is running at 8s with 2/3 agents complete.",
      props: { stage: "running", presentation: "selected", replay: realWorkflowFixture(GALLERY_NOW, 8_760) },
    },
  },
});
