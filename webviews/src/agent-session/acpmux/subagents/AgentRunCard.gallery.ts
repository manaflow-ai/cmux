// l10n-allow-file: gallery fixtures with synthetic commands, sessions and replies, not shipped UI.
// AgentRunCard is reserved for a child session explicitly recorded by acpmux. Shell commands
// without that signal are covered by ShellAgentIdentity.gallery.ts and stay normal tool rows.
import { agentPaneEntry } from "../../../gallery/format";
import { chat, session, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SubagentFold } from "./subagentFold";

function tracked(completed: boolean, failed = false) {
  const fold = new SubagentFold();
  fold.harness = "claude";
  const command = 'acpmux run --parent chat-1 -n fix "Fix the flaky socket test"';
  const update = {
    sessionUpdate: "tool_call",
    toolCallId: "fix-call",
    title: command,
    kind: "execute",
    status: "in_progress",
    rawInput: { command },
  };
  fold.reduce({ seq: 1, at: minutesAgo(4), msg: { params: { update } } }, update);
  fold.reduceChild(
    { seq: 2, at: minutesAgo(3.9) },
    {
      event: "started",
      childSessionId: "child-fix",
      shortName: "fix",
      harness: "codex",
      model: "gpt-6-astra",
      effort: "xhigh",
      state: "running",
    },
  );
  if (completed)
    fold.reduceChild(
      { seq: 3, at: minutesAgo(0.9) },
      {
        event: "turn_ended",
        childSessionId: "child-fix",
        state: failed ? "failed" : "done",
        result: failed
          ? { error: "The session could not complete the review." }
          : { reply: "Fixed: the test waits for the socket before it connects, so it no longer races the server." },
      },
    );
  const snapshot = chat([user("Have the tracked reviewer fix the flaky socket test.", 4.2), ...fold.takeRows()], {
    isWorking: !completed,
  });
  return {
    ...snapshot,
    sessions: [
      ...snapshot.sessions,
      session({ sessionId: "child-fix", name: "fix", title: "Fix the flaky socket test", harness: "codex" }),
    ],
  };
}

export default agentPaneEntry({
  id: "agent-pane.agent-runs",
  title: "Recorded child sessions",
  area: "Agent pane",
  height: 620,
  covers: ["agent-session/acpmux/subagents/AgentRunCard.tsx"],
  variants: {
    "card-running": {
      note: "The explicit child-session record supplies the Codex identity and running state.",
      snapshot: tracked(false),
    },
    "card-done": {
      note: "The child session's turn-end record supplies its reply; Open chat uses its actual session id.",
      snapshot: tracked(true),
    },
    "card-failed": {
      note: "A failed tracked session retains the error from its explicit turn-end record.",
      snapshot: tracked(true, true),
    },
  },
});
