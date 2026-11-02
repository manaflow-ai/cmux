// l10n-allow-file: gallery fixtures with synthetic commands, sessions and replies, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, session, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SubagentFold } from "./subagentFold";

const SHELL = `reach review-router 'codex exec --sandbox read-only -m gpt-6-astra -c model_reasoning_effort=xhigh "Review the branch"'`;
const CHILD = 'acpmux run --parent chat-1 -n protocol-review "Review the tests"';

/// Exercise the production identity fold. A call the fold doesn't consume stays a normal tool row.
function snapshot(completed: boolean) {
  const fold = new SubagentFold();
  fold.harness = "claude";
  let seq = 0;
  const send = (update: Record<string, unknown>) =>
    fold.reduce({ seq: ++seq, at: minutesAgo(2), msg: { params: { update } } }, update);
  const status = completed ? "completed" : "in_progress";
  const output = "OpenAI Codex\nmodel: gpt-6-astra\nhost: review-router\nVERDICT: SHIP";
  const call = (id: string, command: string) => ({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: command,
    kind: "execute",
    status: "in_progress",
    rawInput: { command },
  });
  const shellIsAgent = send(call("shell-review", SHELL));
  if (completed)
    send({
      sessionUpdate: "tool_call_update",
      toolCallId: "shell-review",
      status,
      content: [{ type: "content", content: { type: "text", text: output } }],
    });
  const shell = shellIsAgent
    ? fold.takeRows()
    : [
        activity(
          [
            tool(SHELL, "execute", status, {
              command: SHELL,
              inputSummary: JSON.stringify({ command: SHELL }),
              startedAt: minutesAgo(2),
              ...(completed && { output, endedAt: minutesAgo(1) }),
            }),
          ],
          2,
        ),
      ];
  send(call("protocol-review", CHILD));
  const record = (fields: Record<string, unknown>) =>
    fold.reduceChild(
      { seq: ++seq, at: minutesAgo(1.8), msg: fields },
      {
        childSessionId: "protocol-session",
        shortName: "protocol-review",
        harness: "codex",
        model: "gpt-6-astra",
        effort: "xhigh",
        ...fields,
      },
    );
  record({ event: "started", state: "running" });
  if (completed)
    record({ event: "turn_ended", state: "done", result: { reply: "The tests cover the reported command." } });
  const result = chat(
    [user("Run the shell review, then start a tracked reviewer.", 2.2), ...shell, ...fold.takeRows()],
    {
      isWorking: !completed,
    },
  );
  return {
    ...result,
    sessions: [
      ...result.sessions,
      session({ sessionId: "protocol-session", name: "protocol-review", title: "Review the tests", harness: "codex" }),
    ],
  };
}

export default agentPaneEntry({
  id: "agent-pane.shell-agent-identity",
  title: "Shell calls and tracked sessions",
  area: "Agent pane",
  height: 680,
  covers: ["agent-session/acpmux/subagents/AgentRunCard.tsx"],
  variants: {
    running: {
      note: "Bash stays a shell row. Only the explicit child-session record supplies the Codex card.",
      snapshot: snapshot(false),
    },
    completed: {
      note: "Codex-looking stdout stays shell output; the tracked child's reply comes from its session record.",
      snapshot: snapshot(true),
    },
  },
});
