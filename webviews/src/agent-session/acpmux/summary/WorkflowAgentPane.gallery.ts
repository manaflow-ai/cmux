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
  title: "Open a workflow agent beside its chat",
  area: "Agent pane",
  height: 720,
  covers: ["agent-session/acpmux/summary/workflowTranscript.ts", "agent-session/acpmux/App.tsx"],
  variants: {
    "open-agent": {
      note: "Click a running agent in Session Info. The native call carries the workflow session/run/agent identity and keeps the parent chat visible. Native placement requires a real-app capture.",
      snapshot,
      workflowLabs: true,
      native: { "pane.tabState": { inspector: true }, "chat.subagentPane": { opened: true } },
      play: async (ctx) => {
        const selector = ".acpmux-workflow-phase__agents .acpmux-workflow-agent__button:not(:disabled)";
        await ctx.waitFor(() => ctx.document.querySelector(selector));
        await ctx.click({ selector });
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: PaneCall[] }).cmuxGalleryLog;
        await ctx.waitFor(() => log.some((call) => call.method === "chat.subagentPane"));
        const call = log.find((entry) => entry.method === "chat.subagentPane")!;
        const request = workflowPaneRequest(String(call.params?.subagent));
        if (
          request?.sessionId !== snapshot.sessionId ||
          !request?.runId ||
          !request.agentId ||
          call.params?.focus !== true
        )
          throw new Error("Workflow click lost its transcript identity or focus");
        if (ctx.document.querySelector(".cv-subagent-of")) throw new Error("Parent chat switched to the child");
      },
    },
  },
});
