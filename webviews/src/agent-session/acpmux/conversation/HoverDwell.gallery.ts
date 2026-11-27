// l10n-allow-file: gallery fixtures (sample messages), not shipped UI.
// User-message actions appear instantly (Lucas, 2026-11-13). Browser tests brush a prompt,
// stay on another, and tab into a third. Other controls keep the shared dwell ramp.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const rows = () =>
  chat([
    user("Can my message actions appear without a fade?", 9, { seq: 1 }),
    assistant("Yes. Your message controls show and hide at once.", 8.6),
    summary(8.6, { status: "completed", toolCount: 0 }),
    user("Make the user actions appear immediately.", 7, { seq: 3 }),
    assistant("Moving over a prompt reveals its actions in one frame.", 6.5),
    summary(6.5, { status: "completed", toolCount: 0 }),
    user("And from the keyboard?", 2, { seq: 5 }),
    assistant("Tab shows the controls at full at once.", 1.8),
    summary(1.8, { status: "completed", toolCount: 0 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.hover-dwell",
  title: "User-message actions appear instantly",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx", "agent-session/acpmux/conversation/AgentMessageRow.tsx"],
  variants: {
    rest: {
      note: "Three prompts and replies at rest: user-message actions appear instantly on hover or keyboard focus.",
      snapshot: rows(),
    },
  },
});
