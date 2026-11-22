// l10n-allow-file: gallery notes, not shipped UI.
// When a running turn's run of messages folds into one line. Leo, 2026-11-21: "the messages and
// whatever collapsing and stuff, sometimes it does so too soon in the midst of a turn. thats not
// great." On the run's second line it folded, the run the agent was still in included, and the
// message steered in then and the next call went under the closed line. `<html data-message-run-fold>`
// picks when it folds (messageRuns.ts `messageRunFoldLook`); test/turn-gap-early-fold.test.ts holds
// the shipped timing. Each variant is the chat after one event of the same turn.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import { recordingOf, STEERED } from "./turnGapEarlyFoldEvents";

const CHAT = "0190a000-0000-7000-8000-0000000000f9";

const snapshot = (working: boolean) => {
  const base = chat([], { title: "Coordinate the lanes" });
  return working
    ? {
        ...base,
        isWorking: true,
        sessions: base.sessions.map((session) => ({ ...session, status: "working" as const })),
      }
    : base;
};

/// The chat after its `events`th event, folding as `look` does.
const after = (note: string, events: number, look?: string): AgentPaneVariant => ({
  note,
  snapshot: snapshot(events < STEERED.length),
  recording: recordingOf(CHAT, STEERED.slice(0, events)),
  ...(look && { documentAttributes: { "message-run-fold": look } }),
});

export default agentPaneEntry({
  id: "agent-pane.message-run-fold-timing",
  title: "When a running turn's run of messages folds",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/messageRuns.ts#foldMessageRuns"],
  variants: {
    "run-end": after(
      "Shipped, mid-turn: a message came in and the agent ran another command. The run it is in stays open, each call and the message in sight.",
      7,
    ),
    "run-end-said": after(
      "Shipped, the agent's paragraph ends the run: it folds into one line now, as a run of calls folds.",
      8,
    ),
    now: after(
      "Before, mid-turn: the run folded on its second line, the run the agent was still in, so the steered message and the next call went under a closed line.",
      7,
      "now",
    ),
    "turn-end": after("Alternative, mid-turn: nothing folds until the turn ends.", 7, "turn-end"),
    "turn-end-said": after(
      "Alternative, the agent's paragraph: still open; it folds at the turn's end only.",
      8,
      "turn-end",
    ),
    ended: after("Every arm, the turn ended: the run is one line under Worked for.", 9),
  },
});
