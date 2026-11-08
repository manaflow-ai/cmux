// l10n-allow-file: gallery fixtures (sample messages), not shipped UI.
// A message's hover controls (a prompt's time and Copy, a reply's time, Copy and ⋯) follow how long
// the pointer stays instead of playing a fixed fade (Leo, 2026-11-07: "it should be, like, having
// its limit based off of how long you've had your cursor actually on it. So it doesn't necessarily
// act, like, oh, okay, you had it for a brief instant. It's going to play its full animation and go
// to full brightness and then just disappear"). The stage is a short chat at rest; the pointer is
// the test's (test/hover-reveal-dwell.test.ts brushes a prompt for 80 ms, stays on another, and tabs
// into a third). Gallery ui.motion-hover-dwell compares the ramp curves.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const rows = () =>
  chat([
    user("Why does the hover time flash when I scroll past it?", 9, { seq: 1 }),
    assistant("Its fade played to full however briefly the pointer passed, then faded back.", 8.6),
    summary(8.6, { status: "completed", toolCount: 0 }),
    user("Make it follow how long the pointer stays.", 7, { seq: 3 }),
    assistant("Done: a pass leaves it faint; only a pointer that stays brings it to full.", 6.5),
    summary(6.5, { status: "completed", toolCount: 0 }),
    user("And from the keyboard?", 2, { seq: 5 }),
    assistant("Tab shows the controls at full at once.", 1.8),
    summary(1.8, { status: "completed", toolCount: 0 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.hover-dwell",
  title: "Hover controls follow the pointer's dwell",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/UserBubble.tsx", "agent-session/acpmux/conversation/AgentMessageRow.tsx"],
  variants: {
    rest: {
      note: "Three prompts and replies at rest: every hover control hidden until the pointer stays on its row.",
      snapshot: rows(),
    },
  },
});
