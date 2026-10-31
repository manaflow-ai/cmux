// l10n-allow-file: synthetic workflow and gallery controls, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { createWorkflowAdapter } from "../summary/foldWorkflows";
import { workflowFixture } from "../summary/workflowFixture";
import { WorkflowTasks } from "./WorkflowTasks";

/// The same mounted run receives a terminal event, as it does in the live Inspector.
function WorkflowLifecycle() {
  const [finished, setFinished] = useState(false);
  const [snapshots] = useState(() => {
    const now = Date.now();
    const running = createWorkflowAdapter()(workflowFixture("running", now), "gallery-chat")[0]!;
    const completed = createWorkflowAdapter()(workflowFixture("finished", now), "gallery-chat")[0]!;
    return {
      running,
      completed: {
        ...completed,
        agents: completed.agents.map((agent) => ({
          ...agent,
          lastMessage: "Review complete. The selected name meets all criteria.",
        })),
      },
    };
  });
  const current = finished ? snapshots.completed : snapshots.running;
  return (
    <div className="acpmux-shell" style={{ padding: 16 }}>
      <button type="button" onClick={() => setFinished(true)}>
        Complete workflow
      </button>
      <WorkflowTasks workflows={[current]} onOpenWorkflowAgent={() => undefined} />
    </div>
  );
}

export default componentEntry({
  id: "agent-pane.workflow-lifecycle",
  title: "Workflow completion",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 320, normal: 420 },
  covers: ["agent-session/acpmux/inspector/WorkflowTasks.tsx"],
  load: async () => WorkflowLifecycle,
  variants: {
    completed: {
      note: "The running Critique phase stays open when the workflow completes, exposing its final agent results without another click.",
      props: {},
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Complete workflow" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-workflow-task[data-state="completed"]'));
      },
    },
  },
});
