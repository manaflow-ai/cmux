// l10n-allow-file: gallery fixture (sample workflow, phase and agent names), not shipped UI.
// A Claude workflow's card in the transcript (Labs `workflowLabs`, WorkflowCard.tsx), drawn from a
// workflow's events fed through the real subagent fold (workflowFixture.ts): its name, "Workflow ·
// N agents · time" and a dot per agent, live while it runs. A click opens Session Info's
// Background tasks (inspector/WorkflowTasks.tsx), whose gallery is agent-pane.chat-inspector.
import { componentEntry } from "../../../gallery/format";
import { configureWorkflowCardOpen, WorkflowCard } from "./WorkflowCard";
import { workflowFixture, type WorkflowFixtureStage } from "./workflowFixture";

type Props = { stage: WorkflowFixtureStage };

/// The gallery's cards open nothing, but draw as the chat's do: a button.
configureWorkflowCardOpen(() => undefined);

function GalleryWorkflowCard({ stage }: Props) {
  const nodes = workflowFixture(stage).filter((node) => node.kind === "workflow");
  return (
    <div className="acpmux-shell" style={{ padding: "16px 20px" }}>
      {nodes.map((node) => (
        <WorkflowCard key={node.id} node={node} />
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.workflow-card",
  title: "Workflow card",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/summary/WorkflowCard.tsx",
    "agent-session/acpmux/summary/workflowDots.css",
    "agent-session/acpmux/subagents/runningTray.ts",
  ],
  load: async () => GalleryWorkflowCard,
  variants: {
    running: {
      note: "Labs: a workflow running where it started in the transcript. demo-name-tournament, Workflow · 6 agents · 13s, a dot per agent: three done (filled), one running (the accent), two queued (outlines). Opens Session Info's Background tasks.",
      props: { stage: "running" },
    },
    finished: {
      note: "Labs: the same workflow finished. Workflow · 7 agents · 1m 20s, every dot filled; the card stays where it started and no done line repeats it.",
      props: { stage: "finished" },
    },
  },
});
