// l10n-allow-file: synthetic workflow fixture, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
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

export default agentPaneEntry({
  id: "agent-pane.workflow-agent-pane",
  title: "View a workflow agent in its chat",
  area: "Agent pane",
  height: 720,
  covers: ["agent-session/acpmux/summary/workflowTranscript.ts", "agent-session/acpmux/App.tsx"],
  variants: {
    "open-agent": {
      note: "With Open subagents in panes off, click an agent in Session Info. Its transcript opens inside the chat with the workflow session/run/agent identity, without a new pane.",
      snapshot,
      workflowLabs: true,
      native: { "pane.tabState": { inspector: true }, "chat.subagentPane": { opened: true } },
      play: async (ctx) => {
        const selector = ".acpmux-workflow-phase__agents .acpmux-workflow-agent__button:not(:disabled)";
        await ctx.waitFor(() => ctx.document.querySelector(selector));
        await ctx.click({ selector });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-of"));
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: PaneCall[] }).cmuxGalleryLog;
        const row = ctx.document.querySelector(".cv-subagent-of")?.closest<HTMLElement>("[data-row-id]");
        const request = workflowPaneRequest(row?.dataset.rowId?.replace(/:of$/, ""));
        if (request?.sessionId !== snapshot.sessionId || !request?.runId || !request.agentId)
          throw new Error("Workflow click lost its transcript identity");
        if (log.some((call) => call.method === "chat.subagentPane")) throw new Error("Workflow click opened a pane");
      },
    },
  },
});
