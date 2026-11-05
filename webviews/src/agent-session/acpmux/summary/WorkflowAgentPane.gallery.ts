// l10n-allow-file: synthetic workflow fixture, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { GALLERY_NOW } from "../../../gallery/clock";
import { chat, row, user } from "../../../gallery/fixtures/acpmux";
type PaneCall = { method: string; params?: { subagent?: string; focus?: boolean } };
import { SUBAGENTS } from "../subagents/subagentFold";
import { workflowFixture } from "./workflowFixture";
import { workflowPaneRequest } from "./workflowTranscript";

const snapshot = chat(
  [user("Run the naming workflow", 1), row(SUBAGENTS, 0.5, { subagents: workflowFixture("running", GALLERY_NOW) })],
  { isWorking: true, title: "Workflow agent transcript" },
);

/// Phases start as one row each: open Critique, the phase whose agent runs, before clicking that agent.
const openCritique = async (ctx: PlayContext) => {
  const head = ".acpmux-workflow-phase:nth-child(2) .acpmux-workflow-phase__head:not(:disabled)";
  await ctx.waitFor(() => ctx.document.querySelector(head));
  ctx.document.querySelector(head)?.scrollIntoView({ block: "center" });
  await ctx.click({ selector: head });
};

export default agentPaneEntry({
  id: "agent-pane.workflow-agent-pane",
  title: "View a workflow agent in its chat",
  area: "Agent pane",
  height: 720,
  covers: ["agent-session/acpmux/summary/workflowTranscript.ts", "agent-session/acpmux/App.tsx"],
  variants: {
    "open-agent": {
      note: "With Open subagents in panes off, click an agent in Session Info. It opens in a pane right of the chat (one chat.subagentPane, focused) with the workflow session/run/agent identity; the chat's pane and its Session Info stay on the chat.",
      snapshot,
      workflowLabs: true,
      native: { "pane.tabState": { inspector: true }, "chat.subagentPane": { opened: true } },
      play: async (ctx) => {
        await openCritique(ctx);
        const selector = ".acpmux-workflow-phase__agents .acpmux-workflow-agent__button:not(:disabled)";
        await ctx.waitFor(() => ctx.document.querySelector(selector));
        await ctx.click({ selector });
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: PaneCall[] }).cmuxGalleryLog;
        await ctx.waitFor(() => log.some((call) => call.method === "chat.subagentPane"));
        const calls = log.filter((call) => call.method === "chat.subagentPane");
        if (calls.length !== 1 || calls[0]?.params?.focus !== true)
          throw new Error("Workflow click did not open exactly one focused pane");
        const request = workflowPaneRequest(calls[0]?.params?.subagent);
        if (request?.sessionId !== snapshot.sessionId || !request?.runId || !request.agentId)
          throw new Error("Workflow click lost its transcript identity");
        if (ctx.document.querySelector(".cv-subagent-of")) throw new Error("Workflow click swapped the chat's pane");
      },
    },
    "open-agent-in-chat": {
      note: "A host that opens no pane (no chat.subagentPane answer): clicking an agent in Session Info shows its transcript inside the chat with the workflow session/run/agent identity.",
      snapshot,
      workflowLabs: true,
      native: { "pane.tabState": { inspector: true } },
      play: async (ctx) => {
        await openCritique(ctx);
        const selector = ".acpmux-workflow-phase__agents .acpmux-workflow-agent__button:not(:disabled)";
        await ctx.waitFor(() => ctx.document.querySelector(selector));
        await ctx.click({ selector });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of"));
        const row = ctx.document.querySelector(".cv-subagent-of")?.closest<HTMLElement>("[data-row-id]");
        const request = workflowPaneRequest(row?.dataset.rowId?.replace(/:of$/, ""));
        if (request?.sessionId !== snapshot.sessionId || !request?.runId || !request.agentId)
          throw new Error("Workflow click lost its transcript identity");
      },
    },
  },
});
