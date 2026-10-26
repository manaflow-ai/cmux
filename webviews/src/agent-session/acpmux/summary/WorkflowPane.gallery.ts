// l10n-allow-file: gallery fixture (a sample prompt, reply, workflow and agent names), not shipped UI.
// A Claude workflow in the whole pane (Labs `workflowLabs`): its card where it started in the
// transcript (WorkflowCard.tsx) and Session Info open beside it, whose Background tasks lists the
// run's phases and agents (inspector/WorkflowTasks.tsx). Both read the same fold data: a
// workflow's events fed through the real subagent fold (workflowFixture.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { SUBAGENTS } from "../subagents/subagentFold";
import { workflowFixture, type WorkflowFixtureStage } from "./workflowFixture";

const PROMPT = "Show me how dynamic workflows work by running a small one";
const REPLY =
  "I started a small demo workflow. It picks a name for a command-line tool that syncs dotfiles: three agents brainstorm, each brainstorm gets a critic, and a judge picks the winner.";
const paneSnapshot = (stage: WorkflowFixtureStage) => {
  const nodes = workflowFixture(stage, GALLERY_NOW).filter((node) => node.kind === "workflow");
  const started = stage === "running" ? 13 / 60 : 2;
  return chat(
    [
      user(PROMPT, started + 0.2),
      row(SUBAGENTS, started, { subagents: nodes }),
      assistant(REPLY, started - 0.1),
      ...(stage === "finished"
        ? [assistant("The judge picked “dotsync”, with “homebase” as the runner-up.", 0.5)]
        : []),
    ],
    { isWorking: stage === "running", title: "Dynamic workflows" },
  );
};
/// The app offers Session Info (Debug Settings `agent.inspector`, on by default): it opens shown.
const native = { "pane.tabState": { inspector: true } };
const shown: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-card"), { capMs: 3000 });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-workflow-task"), { capMs: 3000 });
};

export default agentPaneEntry({
  id: "agent-pane.workflow-pane",
  title: "Workflow in the chat and in Session Info",
  area: "Agent pane",
  height: 720,
  covers: [
    "agent-session/acpmux/summary/WorkflowCard.tsx",
    "agent-session/acpmux/inspector/WorkflowTasks.tsx",
    "agent-session/acpmux/summary/foldWorkflows.ts",
  ],
  variants: {
    running: {
      note: "Labs: a workflow running. The transcript has its card where it started (demo-name-tournament, Workflow · 6 agents · 13s, a dot per agent). Session Info's Background tasks lists it: 1 running · 2 queued · 3 done · 185k tokens, Brainstorm 3 done, Critique open with Model: Opus 5.5 and punchy running beside two Queued, then Up next: Judge.",
      snapshot: paneSnapshot("running"),
      native,
      workflowLabs: true,
      play: shown,
    },
    finished: {
      note: "Labs: the same workflow finished. The card reads Workflow · 7 agents · 1m 20s with every dot filled; Background tasks reads Workflow · Finished · 7 agents · 432k tokens, each phase N/N.",
      snapshot: paneSnapshot("finished"),
      native,
      workflowLabs: true,
      play: shown,
    },
  },
});
