// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A person's own messages with nothing drawn between them (steers sent right after the prompt) stick
// together as one group, the footer gap (8) apart (Leo, 2026-11-27: "these cases are maybe taste calls, but
// potentially we can just stick the steered together. not sure tho."). The upper bubbles' action rows sit
// beside their bubbles on hover, not in the gap. `<html data-own-message-gap>` picks the look
// (transcriptGrid.ts `ownMessagesJoin`); test/steer-group-gap.test.ts holds it.
//
// - `grouped`: shipped. The prompt and its two steers read as one group.
// - `before`: each message stood the turn gap (32) apart, as three turns.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const rows = () => [
  user("Fix the session list ordering", 3, { seq: 1 }),
  user("newest first", 2.9, { steer: "landed" }),
  user("and keep pinned ones on top", 2.8, { steer: "landed" }),
  activity([tool("Read SessionList.tsx", "read", "completed")], 2.6),
  assistant("Sorted the list newest first, with pinned sessions kept above the rest.", 2),
  summary(1.9, { status: "completed" }),
];

export default agentPaneEntry({
  id: "agent-pane.steer-group",
  title: "A person's adjacent messages stick together",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/transcriptGrid.ts#transcriptGap", "agent-session/acpmux/transcript/rowFrames.tsx"],
  variants: {
    grouped: {
      note: "Shipped: the prompt and the steers sent right after it stand the footer gap (8) apart, one group.",
      snapshot: chat(rows(), { title: "Session list" }),
    },
    before: {
      note: "Before: each stood the turn gap (32) apart, three turns in a row.",
      snapshot: chat(rows(), { title: "Session list" }),
      documentAttributes: { "own-message-gap": "turn" },
    },
  },
});
