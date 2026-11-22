// l10n-allow-file: gallery fixture (sample workflow phases and agents), not shipped UI.
// Three full-height arrangements are kept here so the shipped timeline can be compared with
// swimlanes and a compact phase table without changing the chat's live surface.
import { componentEntry } from "../../../gallery/format";
import { workflowFixture, type WorkflowFixtureStage } from "./workflowFixture";
import { workflowOf } from "./foldWorkflows";
import { WorkflowSideTab, type WorkflowSideTabLayout } from "./WorkflowSideTab";

type Props = { stage: WorkflowFixtureStage; layout: WorkflowSideTabLayout };

function GalleryWorkflowSideTab({ stage, layout }: Props) {
  const node = workflowFixture(stage).find((entry) => entry.kind === "workflow");
  if (!node) return null;
  return (
    <div className="acpmux-shell">
      <WorkflowSideTab
        workflow={workflowOf(node, "gallery")}
        layout={layout}
        onClose={() => undefined}
        onStop={async () => undefined}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.workflow-side-tab",
  title: "Workflow side tab",
  area: "Agent pane",
  pane: true,
  height: 720,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/summary/WorkflowSideTab.tsx",
    "agent-session/acpmux/summary/WorkflowSideTab.css",
    "agent-session/acpmux/session-info/WorkflowTasks.tsx",
  ],
  load: async () => GalleryWorkflowSideTab,
  variants: {
    timeline: {
      note: "Labs: full-height side tab with a running workflow. A vertical phase timeline keeps phase state and every agent row in one scan.",
      props: { stage: "running", layout: "timeline" },
    },
    lanes: {
      note: "Labs: gallery alternative. Each phase is a horizontal swimlane with its agents grouped together.",
      props: { stage: "running", layout: "lanes" },
    },
    table: {
      note: "Labs: gallery alternative. One compact row per agent keeps the phase column visible for dense runs.",
      props: { stage: "finished", layout: "table" },
    },
  },
});
