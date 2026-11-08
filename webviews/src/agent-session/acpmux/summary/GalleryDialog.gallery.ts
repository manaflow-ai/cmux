// l10n-allow-file: gallery fixtures (sample prompts, replies and render HTML), not shipped UI.
// The chat's gallery (GalleryDialog.tsx): the summary's Outputs section offers it once the chat has
// images or renders; it opens over the pane as a grid, filtered by kind, and an image opens the
// image viewer. In the gallery's widths the pane has no room for the summary's inline column
// (summary/cardState.ts, #21564), so the summary is the popover the header's Summary button opens;
// a pane wide enough shows the column on its own.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
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

const toolOutputs = () =>
  chat(
    [
      user("Capture the chart and show the request flow", 3),
      activity(
        [
          tool("Capture chart", "read", "completed", {
            images: [`data:image/svg+xml;base64,${btoa(sampleChart())}`],
          }),
        ],
        2,
      ),
      assistant(`Captured the chart. Here is the request flow.\n\n${image("Request flow", sampleDiagram())}`, 1),
      summary(1, { status: "completed", toolCount: 1 }),
    ],
    { title: "Capture the chart and show the request flow" },
  );

/** Shows the summary from the header's Summary button unless it shows already (a pane wide enough
 * for its inline column shows it on its own), and waits for Outputs' gallery row. */
const showOutputs = async (ctx: PlayContext) => {
  if (ctx.find({ selector: ".acpmux-summary-button" }).getAttribute("aria-pressed") !== "true")
    await ctx.click({ selector: ".acpmux-summary-button" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-gallery"));
};

const openGallery = async (ctx: PlayContext) => {
  await showOutputs(ctx);
  await ctx.click({ selector: ".acpmux-summary-gallery" });
};

export default agentPaneEntry({
  id: "agent-pane.chat-gallery",
  title: "Chat gallery",
  area: "Agent pane",
  covers: ["agent-session/acpmux/summary/GalleryDialog.tsx", "agent-session/acpmux/summary/SummaryBody.tsx"],
  // The gallery opens over the pane; nothing under it moves.
  // Opening the summary may intentionally reserve the inline column in a wide pane. Keep the
  // shell as the stable anchor while the chat column moves inward.
  anchors: [{ selector: ".acpmux-shell" }],
  checks: {
    layoutShiftMax: {
      value: 0.1,
      reason:
        "A kind filter changes the gallery's grid on purpose, and opening the summary may move the chat inward to reserve its inline column. The shell remains stable.",
    },
  },
  variants: {
    "tool-outputs": {
      note: "A completed tool screenshot and a reply image both appear in Gallery.",
      snapshot: toolOutputs(),
      play: openGallery,
    },
    "tool-image": {
      note: "A tool screenshot opens the existing image viewer and closes Gallery.",
      snapshot: toolOutputs(),
      play: async (ctx) => {
        await openGallery(ctx);
        await ctx.click({ selector: '[data-gallery-kind="tool"] [data-open-image]' });
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-chat-gallery"));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-image-viewer"));
      },
    },
    outputs: {
      note: "Play: show the summary; Outputs offers the gallery with its five items.",
      snapshot: media(),
      play: showOutputs,
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
