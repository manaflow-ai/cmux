// l10n-allow-file: gallery fixtures (sample prompts, replies and render HTML), not shipped UI.
// Several renders of one turn side by side (RenderGroup.tsx), one marked Recommended; Expand on
// one shows it alone with Show all (that state needs a click, so it waits for play steps).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { listMock, pricingCard, renderTool } from "../../../gallery/fixtures/renders";

const options = (prompt: string, renders: Parameters<typeof renderTool>[0][], answer: string) =>
  chat([
    user(prompt, 6),
    activity(renders.map(renderTool), 5.5),
    assistant(answer, 5),
    summary(5, { status: "completed", toolCount: renders.length, durationMs: 64_000 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.render-group",
  title: "Render options",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/RenderGroup.tsx"],
  variants: {
    "two-options": {
      note: "Two options, the first recommended.",
      snapshot: options(
        "Tighten markdown list spacing",
        [
          { html: listMock(4), title: "Nested 4 px", recommended: true },
          { html: listMock(8), title: "Nested 8 px" },
        ],
        "Two spacings for nested lists. I'd take 4 px: the nesting still reads and long lists stay short.",
      ),
    },
    "three-options": {
      note: "Three plan cards in a row, the middle one recommended.",
      snapshot: options(
        "Mock three pricing cards",
        [
          { html: pricingCard("Free", "$0", "#64748b"), title: "Free" },
          { html: pricingCard("Pro", "$20/mo", "#3b82f6"), title: "Pro", recommended: true },
          { html: pricingCard("Team", "$40/mo", "#8b5cf6"), title: "Team" },
        ],
        "Pro leads: it is the plan most people pick, so it gets the accent.",
      ),
    },
    "five-options": {
      note: "More options than a row holds wrap to a second row; a tall one is capped.",
      snapshot: options(
        "Try five accent colors on the plan card",
        ["#3b82f6", "#8b5cf6", "#10b981", "#f59e0b", "#ef4444"].map((accent, index) => ({
          html: pricingCard("Pro", "$20/mo", accent, index === 4 ? 16 : 4),
          title: accent,
          recommended: index === 0,
        })),
        "Blue reads best on both themes; red looks like an error.",
      ),
    },
  },
});
