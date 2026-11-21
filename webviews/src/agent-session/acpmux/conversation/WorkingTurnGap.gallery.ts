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
    block: variant(
      "Shipped: a block gap (24) between the message and the turn's Working for line, as between any two blocks. It stays when the line becomes Worked for.",
    ),
    flush: variant("Before: flush (0); the line reads as the message's own tail.", "flush"),
    run: variant("Alternative: a run gap (16), as between two tool runs.", "run"),
    turn: variant("Alternative: the turn gap (32), as under a person's prompt.", "turn"),
    // Before the turn's first call: the live line is the row right under the message.
    thinking: variant(
      "Shipped, before the first call: the live line stands the same block gap (24) under the message, as under a person's prompt.",
      undefined,
      OPENED_BY_MESSAGE.slice(0, 8),
    ),
    "thinking-before": variant(
      "Before: the live line stood a run gap (16) under the message, as under a tool run.",
      "run",
      OPENED_BY_MESSAGE.slice(0, 8),
    ),
  },
});
