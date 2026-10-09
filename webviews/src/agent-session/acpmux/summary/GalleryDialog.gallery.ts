// l10n-allow-file: gallery fixtures (sample prompts, replies and render HTML), not shipped UI.
// The chat's gallery (GalleryDialog.tsx): the summary's Outputs section offers it once the chat has
// images or renders; it opens over the pane as a grid, filtered by kind, and an image opens the
// image viewer.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { latencyChart, pricingCard, renderTool } from "../../../gallery/fixtures/renders";
import { sampleChart, sampleDiagram, sampleGradient } from "../mockFixture";

const image = (alt: string, svg: string) => `![${alt}](data:image/svg+xml;base64,${btoa(svg)})`;

const media = () =>
  chat(
    [
      user("Make sample images for the docs", 12),
      assistant(
        [
          "Made three sample images: a chart, a gradient and a diagram.",
          image("Weekly builds", sampleChart()),
          image("Dusk gradient", sampleGradient()),
          image("Request flow", sampleDiagram()),
        ].join("\n\n"),
        11,
      ),
      summary(11, { status: "completed" }),
      user("Chart typing latency per split layout, then mock the Pro plan card", 8),
      activity(
        [
          renderTool({ html: latencyChart(), title: "Keystroke to paint, ms" }),
          renderTool({ html: pricingCard("Pro", "$20/mo", "#3b82f6"), title: "Pro plan" }),
        ],
        7.5,
      ),
      assistant("Latency stays under 9 ms up to 8 splits. The Pro card keeps the accent.", 7),
      summary(7, { status: "completed", toolCount: 2, durationMs: 41_000 }),
    ],
    { title: "Make sample images for the docs" },
  );

const openGallery = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "Chat summary" });
  await ctx.click({ role: "button", name: "Gallery 5" });
};

export default agentPaneEntry({
  id: "agent-pane.chat-gallery",
  title: "Chat gallery",
  area: "Agent pane",
  covers: ["agent-session/acpmux/summary/GalleryDialog.tsx", "agent-session/acpmux/summary/SummaryPopover.tsx"],
  // The gallery opens over the pane; nothing under it moves.
  anchors: [{ selector: ".acpmux-composer" }, { selector: ".acpmux-header" }],
  variants: {
    outputs: {
      note: "Play: open the chat summary; Outputs offers the gallery with its five items.",
      snapshot: media(),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Chat summary" });
        await ctx.waitFor(() => ctx.find({ role: "button", name: "Gallery 5" }));
      },
    },
    open: {
      note: "Play: open the gallery from Outputs; three images, then two render cards waiting to run.",
      snapshot: media(),
      play: async (ctx) => {
        await openGallery(ctx);
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Gallery" }));
      },
    },
    renders: {
      note: "Play: open the gallery and filter to Renders; only the two render cards stay.",
      snapshot: media(),
      play: async (ctx) => {
        await openGallery(ctx);
        await ctx.click({ role: "button", name: "Renders 2" });
      },
    },
    image: {
      note: "Play: open the gallery and click the first image; the image viewer takes its place.",
      snapshot: media(),
      play: async (ctx) => {
        await openGallery(ctx);
        // The gallery's tile, not the same image's button in the transcript under it.
        await ctx.click({ selector: ".acpmux-chat-gallery-image" });
        await ctx.waitFor(() => ctx.find({ role: "dialog", name: "Weekly builds" }));
      },
    },
  },
});
