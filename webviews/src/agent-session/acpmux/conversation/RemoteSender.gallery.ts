// l10n-allow-file: gallery fixtures (sample reports), not shipped UI.
// Reports other agents sent this chat from other machines: a Codex lane's `acpmux send` through
// the peer link, or over ssh with `reach`. acpmux records the sender it was told (`fromAgent`, from
// the lane's session or `ACPMUX_FROM`) as the prompt's provenance (prompt_provenance.rs
// `named_sender`), and the pane draws that lane's card. A daemon that recorded no sender left the
// same report as the person's bubble (claude-sr2, 2026-10-24). A task's result (`acpmux task done`,
// acpmux hub/tasks.rs) is the lane's card too, opening its chat.
import { agentPaneEntry } from "../../../gallery/format";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";

const REPORT =
  "#24927 merged at squash 6f0c2d1. Head bb92c90 had a fresh Codex xhigh SHIP and green CI; the gallery run showed the composer at both widths.";
const CLIENT = "acpmux-peer#01a16e";

/// The report as direct.ts reads its recorded `user_message`, with the sender acpmux recorded.
function report(minutes: number, from?: string) {
  const provenance = from && { kind: "agent_message", from: "fromAgent", fromName: from, to: SESSION_ID };
  const incoming = incomingPrompt(REPORT, { client: CLIENT, ...(provenance && { _meta: { provenance } }) });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: REPORT, untyped: true })
    : user(REPORT, minutes);
}

const TASK_CARD =
  'Task t-1a2b3c4d "Land #24927" done: Merged at squash 6f0c2d1 after a Codex xhigh SHIP\nPR: https://github.com/example/app/pull/24927\nSHA: 6f0c2d1';

/// The result `acpmux task done` brought back, as direct.ts reads its recorded `user_message`.
function taskResult(minutes: number) {
  const provenance = {
    kind: "task_result",
    from: "codex-lane-1",
    fromName: "codex-lane",
    to: SESSION_ID,
    taskId: "t-1a2b3c4d",
    state: "done",
  };
  const incoming = incomingPrompt(TASK_CARD, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: TASK_CARD, untyped: true })
    : user(TASK_CARD, minutes);
}

function snapshot(from?: string, last = report(3, from)) {
  return chat(
    [
      user("Land #24927 once its review passes, then report here.", 9),
      assistant("Sent the order to codex-lane on build-box.", 8.5),
      summary(8.5, { status: "completed" }),
      last,
    ],
    {
      title: "claude-sr2",
      sessions: [
        session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" }),
        session({ sessionId: "codex-lane-1", title: "codex-lane", name: "codex-lane" }),
      ],
    },
  );
}

export default agentPaneEntry({
  id: "agent-pane.remote-sender",
  title: "A report from another machine's agent",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/incomingMessage.ts",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  variants: {
    named: {
      note: "acpmux recorded codex-lane as the sender: its card, with the chip.",
      snapshot: snapshot("codex-lane"),
    },
    "task-result": {
      note: "codex-lane ended its task with acpmux task done: one card from the lane, its PR and squash under the summary.",
      snapshot: snapshot(undefined, taskResult(3)),
    },
    unnamed: {
      note: "A daemon that recorded no sender: the same report reads as the person's bubble.",
      snapshot: snapshot(),
    },
    "person-cli": {
      note: "The person's own acpmux send from a terminal on studio-mac: their bubble, and where they sent it from.",
      snapshot: chat(
        [
          user("Land #24927 once its review passes, then report here.", 9, { viaCli: "studio-mac" }),
          assistant("Sent the order to codex-lane on build-box.", 8.5),
          summary(8.5, { status: "completed" }),
        ],
        {
          title: "claude-sr2",
          sessions: [session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" })],
        },
      ),
    },
  },
});
