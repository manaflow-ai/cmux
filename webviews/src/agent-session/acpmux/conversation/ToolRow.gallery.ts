// l10n-allow-file: gallery fixtures, not shipped UI.
// Visual tool output variants used to compare the compact trailing capture thumbnail and its
// anchored preview against the Claude Desktop reference.
import type { Play } from "../../../gallery/play";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const CAPTURE_DATA =
  "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";
const CAPTURE = `data:image/png;base64,${CAPTURE_DATA}`;

const treatment =
  (css: string): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = css;
    ctx.document.head.append(style);
  };

const capture = (status = "completed") =>
  tool(
    "Capture page",
    "fetch",
    status,
    status === "in_progress"
      ? {
          title: "Capture page",
          output: JSON.stringify([{ type: "image", mimeType: "image/png", data: CAPTURE_DATA }]),
        }
      : {
          title: "Capture page",
          output: "Captured page",
          images: [CAPTURE],
        },
  );

export default agentPaneEntry({
  id: "agent-pane.tool-row-visual-preview",
  title: "Visual tool previews",
  area: "Agent pane",
  height: 720,
  covers: ["agent-session/acpmux/conversation/ToolRow.tsx", "agent-session/acpmux/conversation/ToolVisualPreview.tsx"],
  variants: {
    capture: {
      note: "A completed page capture keeps the tool row compact and puts its live thumbnail at the trailing edge.",
      snapshot: chat([user("Capture the page", 3), activity([capture()], 2), assistant("The page is captured.", 1)]),
    },
    "larger-thumbnail": {
      note: "Alternative: a larger 52px capture tile makes the image easier to see but adds row height. Compact trailing is selected.",
      snapshot: chat([user("Capture the page", 3), activity([capture()], 2)]),
      play: treatment(".cv-tool-visual, .cv-tool-visual .cv-thumb { width: 52px; height: 34px; flex-basis: 52px; }"),
    },
    "leading-thumbnail": {
      note: "Alternative: a leading thumbnail interrupts the shared tool icon column. Compact trailing is selected.",
      snapshot: chat([user("Capture the page", 3), activity([capture()], 2)]),
      play: treatment(".cv-tool-visual { order: -1; }"),
    },
    hover: {
      note: "Hovering or focusing the trailing thumbnail opens the glass Captured page preview card.",
      snapshot: chat([user("Capture the page", 3), activity([capture()], 2)]),
      play: async (ctx) => {
        await ctx.hover({ selector: ".cv-tool-visual" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-tool-visual-card"));
      },
    },
    grouped: {
      note: "An image-bearing step preserves the opened group's quiet icon and disclosure treatment.",
      play: async (ctx) => {
        const group = ctx.document.querySelector(".cv-tool.is-run");
        if (group?.getAttribute("aria-expanded") === "false") await ctx.click({ selector: ".cv-tool.is-run" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-steps .cv-tool-with-visual"));
        const icons = ctx.document.querySelectorAll(".cv-steps .cv-step .cv-tool__icon");
        if (
          icons.length !== 2 ||
          [...icons].some((icon) => ctx.document.defaultView!.getComputedStyle(icon).visibility !== "hidden")
        )
          throw new Error("Capture step must preserve its group's hidden icon treatment");
      },
      snapshot: chat([
        user("Read the captures", 3),
        activity(
          [
            tool("Read first capture", "read", "completed", {
              images: [CAPTURE],
              output: "Captured page",
            }),
            tool("Read second capture", "read", "completed", { output: "Read the page metadata" }),
          ],
          2,
        ),
      ]),
    },
    running: {
      note: "A running capture shows the image from its actual partial result envelope.",
      snapshot: chat([user("Capture the page", 3), activity([capture("in_progress")], 2)]),
    },
  },
});
