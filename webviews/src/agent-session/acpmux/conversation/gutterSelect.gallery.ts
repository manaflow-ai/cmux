// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A drag from the margin beside the chat's column selects text (gutterSelect.ts). Each state plays
// the drag with mouse events at points in the margin, as a hand would: there is no element there to
// aim the gallery's pointer at.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const rows = [
  user("How does the keeper start the night?", 30),
  assistant(
    "Alpha: the keeper climbs to the gallery at dusk, wipes the salt from the lantern glass and trims the wick before lighting it.",
    29.8,
  ),
  summary(29.6, { status: "completed" }),
  user("And when the tide comes in?", 20),
  assistant(
    "Bravo: the tide lifts the moored boats one by one under the jetty, and the keeper logs the height on the hour.",
    19.8,
  ),
  summary(19.6, { status: "completed" }),
  user("What does the gull do?", 10),
  assistant(
    "Charlie: a gull settles on the rail and watches the light sweep across the water until morning.",
    9.8,
  ),
  summary(9.6, { status: "completed" }),
];

/// The middle of the text line `id`'s answer starts on, and the column's edges.
function answerLine(doc: Document, text: string) {
  for (const node of doc.querySelectorAll<HTMLElement>(".acpmux-row .cv-md")) {
    if (!node.textContent?.startsWith(text)) continue;
    const rect = node.getBoundingClientRect();
    const column = node.closest(".acpmux-row")!.getBoundingClientRect();
    return { top: rect.top + 6, bottom: rect.bottom - 6, left: column.left, right: column.right };
  }
  return undefined;
}

/// Presses at (x, y0) in the margin, drags to (x, y1) in steps a frame apart, and lifts.
async function drag(ctx: PlayContext, x: number, y0: number, y1: number) {
  const doc = ctx.document;
  const view = doc.defaultView!;
  const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll")!;
  const init = (y: number, buttons: number): MouseEventInit => ({
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button: 0,
    buttons,
  });
  scroller.dispatchEvent(new MouseEvent("mousedown", init(y0, 1)));
  for (let step = 1; step <= 6; step += 1) {
    view.dispatchEvent(new MouseEvent("mousemove", init(y0 + ((y1 - y0) * step) / 6, 1)));
    await new Promise((resolve) => view.requestAnimationFrame(resolve));
  }
  view.dispatchEvent(new MouseEvent("mouseup", init(y1, 0)));
  await ctx.waitFor(() => !(view.getSelection()?.isCollapsed ?? true), { capMs: 1500 }).catch(() => undefined);
}

export default agentPaneEntry({
  id: "agent-pane.gutter-select",
  title: "Drag-select from the margin",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 900, normal: 1100, wide: 1280 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/conversation/gutterSelect.ts#installGutterSelect"],
  variants: {
    "from-left-margin": {
      note: "Pressed in the left margin beside the first answer and dragged down beside the third: the selection runs from the line beside the press through all three answers, as a document's margin selects.",
      snapshot: chat(rows, { title: "Drag-select from the margin" }),
      play: async (ctx) => {
        const first = answerLine(ctx.document, "Alpha");
        const third = answerLine(ctx.document, "Charlie");
        if (!first || !third || first.left < 40) return;
        await drag(ctx, first.left / 2, first.top, third.bottom);
      },
    },
    "from-right-margin": {
      note: "Pressed in the right margin beside the second answer and dragged up beside the first: the selection runs back from the line beside the press.",
      snapshot: chat(rows, { title: "Drag-select from the margin" }),
      play: async (ctx) => {
        const first = answerLine(ctx.document, "Alpha");
        const second = answerLine(ctx.document, "Bravo");
        if (!first || !second) return;
        const width = ctx.document.documentElement.clientWidth;
        if (width - second.right < 60) return;
        await drag(ctx, (second.right + width - 16) / 2, second.bottom, first.top);
      },
    },
  },
});
