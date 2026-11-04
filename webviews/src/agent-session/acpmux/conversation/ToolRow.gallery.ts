// l10n-allow-file: gallery fixtures, not shipped UI.
// Visual tool output variants used to compare the compact trailing capture thumbnail and its
// anchored preview against the Claude Desktop reference.
import type { Play } from "../../../gallery/play";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const CAPTURE =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='640' height='360'%3E%3Crect width='640' height='360' fill='%232b2b2b'/%3E%3Crect x='24' y='24' width='592' height='48' rx='8' fill='%234f4f4f'/%3E%3Ctext x='44' y='55' fill='white' font-size='22'%3ECaptured page%3C/text%3E%3C/svg%3E";

const CAPTURE_DATA = btoa(decodeURIComponent(CAPTURE.split(",")[1]!));

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
          output: JSON.stringify([{ type: "image", mimeType: "image/svg+xml", data: CAPTURE_DATA }]),
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
  height: 360,
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
    running: {
      note: "A running capture shows the image from its actual partial result envelope.",
      snapshot: chat([user("Capture the page", 3), activity([capture("in_progress")], 2)]),
    },
  },
});
