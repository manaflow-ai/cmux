// l10n-allow-file: gallery fixture (a sample workflow run and one agent's transcript), not shipped UI.
// The Background tasks panel with a Claude workflow in it (BackgroundTasksPanel.tsx): the workflow's
// agents that started are its tasks, and one opens its transcript in the panel, read through acpmux
// as the app's workflow pane reads it (summary/useWorkflowTranscript.ts), never a blank pane (Leo,
// 2026-10-29: "i also like the way it just loads in the subagent stuff instantly :(").
import { componentEntry } from "../../../gallery/format";
import type { AcpmuxRow } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";
import { workflowFixture } from "../summary/workflowFixture";
import { workflowPaneId, type TranscriptRead } from "../summary/workflowTranscript";
import { backgroundGroups } from "./backgroundTasks";
import { BackgroundTasksPanel } from "./BackgroundTasksPanel";

type Props = { drill: boolean; loads: boolean };

const SESSION = "gallery";
const text = (sessionUpdate: string, value: string) => ({ sessionUpdate, content: { type: "text", text: value } });
const PAGE = {
  start: 0,
  end: 6,
  lines: 6,
  truncated: false,
  updates: [
    text("user_message_chunk", "Critique the punchy names against the brief and keep the strongest three."),
    text("agent_thought_chunk", "The brief wants names that read at a glance; I'll score each against it."),
    { sessionUpdate: "tool_call", toolCallId: "read", title: "Read brief.md", kind: "read", status: "in_progress" },
    {
      sessionUpdate: "tool_call_update",
      toolCallId: "read",
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "Short, concrete, no puns." } }],
    },
    text("agent_message_chunk", "Kept **Relay**, **Dock** and **Lane**: each reads in one glance and none is a pun."),
  ],
};

function GalleryWorkflowPanel({ drill, loads }: Props) {
  const nodes = workflowFixture("running");
  const rows: AcpmuxRow[] = [{ id: "wf", version: 1, at: 0, kind: SUBAGENTS, subagents: nodes }];
  const groups = backgroundGroups({ rows, commands: [], sessions: [], chatName: "This chat", sessionId: SESSION });
  const read: TranscriptRead = () => (loads ? Promise.resolve(PAGE) : new Promise<never>(() => undefined));
  const pane = workflowPaneId({ sessionId: SESSION, runId: "wf_7c2e91", agentId: "a4" });
  return (
    <div className="acpmux-shell" style={{ height: "100%" }}>
      <BackgroundTasksPanel
        groups={groups}
        initialDrill={drill ? { agentId: pane, workflow: true } : undefined}
        workflow={{ sessionId: SESSION, chat: "This chat", connection: "connected", read }}
        onClearFinished={() => undefined}
        onExpand={() => undefined}
        onClose={() => undefined}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.background-tasks-workflow",
  title: "Background tasks panel: a workflow",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx",
    "agent-session/acpmux/backgroundTasks/backgroundTasks.ts",
  ],
  load: async () => GalleryWorkflowPanel,
  variants: {
    list: {
      note: "A running workflow's block: its agents that started are its tasks, the running one first, then the finished ones.",
      props: { drill: false, loads: true },
    },
    loading: {
      note: "A workflow agent opened before acpmux answered: the transcript's Loading line, never a blank pane.",
      props: { drill: true, loads: false },
    },
    transcript: {
      note: "The workflow agent's transcript once its first page lands: its prompt, thought, tool call and reply.",
      props: { drill: true, loads: true },
    },
  },
});
