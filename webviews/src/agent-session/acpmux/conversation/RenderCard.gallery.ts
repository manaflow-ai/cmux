// l10n-allow-file: gallery fixtures (sample prompts, replies and render HTML), not shipped UI.
// One render card above a turn's answer (RenderCard.tsx): the agent's HTML live in the render
// frame (renderFrame.html, which the gallery serves beside its stage), sized to its content up to
// a cap that Expand lifts.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { latencyChart, pricingCard, renderTool } from "../../../gallery/fixtures/renders";

const turn = (prompt: string, render: Parameters<typeof renderTool>[0], answer: string) =>
  chat([
    user(prompt, 6),
    activity([renderTool(render)], 5.5),
    assistant(answer, 5),
    summary(5, { status: "completed", toolCount: 1, durationMs: 38_000 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.render-card",
  title: "Render card",
  area: "Agent pane",
  covers: ["agent-session/acpmux/conversation/RenderCard.tsx"],
  // The composer and the header stay put while the card loads and sizes.
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    chart: {
      note: "A chart the agent rendered, above its answer.",
      snapshot: turn(
        "Chart typing latency per split layout",
        { html: latencyChart(), title: "Keystroke to paint, ms" },
        "Latency stays under 9 ms up to 8 splits; this branch matches main within 0.3 ms.",
      ),
    },
    tall: {
      note: "A page taller than the cap: the card offers Expand.",
      snapshot: turn(
        "Mock the Pro plan card with every feature",
        { html: pricingCard("Pro", "$20/mo", "#3b82f6", 30), title: "Pro plan" },
        "The card lists all 30 features; the button keeps the accent.",
      ),
    },
    untitled: {
      note: "A render without a title reads Preview.",
      snapshot: turn("Mock the Team plan card", { html: pricingCard("Team", "$40/mo", "#8b5cf6") }, "Here it is."),
    },
  },
});
