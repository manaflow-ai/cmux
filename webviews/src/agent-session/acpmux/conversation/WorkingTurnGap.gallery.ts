// l10n-allow-file: gallery notes, not shipped UI.
// The gap over a turn's "Working for" line when another agent's message opened the turn. Leo,
// 2026-11-21: "it is noticeably bad when you start a new working for whatever and there is no space
// before." The line's mark read as a step's, and a step under a status row (the message) sits flush
// (transcriptGrid.ts `transcriptGap`). `<html data-worked-head-gap>` picks the gap
// (transcriptGrid.ts `workedHeadGapLook`); test/turn-gap-early-fold.test.ts holds the shipped one.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { chat } from "../../../gallery/fixtures/acpmux";
import { OPENED_BY_MESSAGE, recordingOf } from "./turnGapEarlyFoldEvents";

const CHAT = "0190a000-0000-7000-8000-0000000000f8";

const running = () => {
  const base = chat([], { title: "Coordinate the lanes" });
  return {
    ...base,
    isWorking: true,
    sessions: base.sessions.map((session) => ({ ...session, status: "working" as const })),
  };
};

const variant = (note: string, look?: string, steps = OPENED_BY_MESSAGE): AgentPaneVariant => ({
  note,
  snapshot: running(),
  recording: recordingOf(CHAT, steps),
  ...(look && { documentAttributes: { "worked-head-gap": look } }),
});

export default agentPaneEntry({
  id: "agent-pane.working-turn-gap",
  title: "The gap over Working for, in a turn another agent's message opened",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/transcriptGrid.ts#transcriptGap"],
  variants: {
    shipped: variant(
      'Shipped: the run gap (16) "Worked for" stands under any one-line row (#48591, agent-pane.chat-row-spacing), between the message and the turn\'s Working for line. It stays when the line becomes Worked for.',
    ),
    block: variant("Alternative: a block gap (24), as between any two blocks.", "block"),
    flush: variant("Before: flush (0); the line reads as the message's own tail.", "flush"),
    turn: variant("Alternative: the turn gap (32), as under a person's prompt.", "turn"),
    // Before the turn's first call: the live line is the row right under the message.
    thinking: variant(
      "Shipped, before the first call: the live line stands the same gap under the message as Working for does (16).",
      undefined,
      OPENED_BY_MESSAGE.slice(0, 8),
    ),
    "thinking-block": variant(
      "Alternative, before the first call: the live line stands a block gap (24) under the message, as under a person's prompt.",
      "block",
      OPENED_BY_MESSAGE.slice(0, 8),
    ),
  },
});
