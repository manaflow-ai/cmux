// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// A drag from the margin beside the chat's column selects text (gutterSelect.ts). Each state plays
// the drag with mouse events at points in the margin, as a hand would: there is no element there to
// aim the gallery's pointer at.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { GAP_KINDS, gapPair } from "./selectionGaps.fixture";

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
  assistant("Charlie: a gull settles on the rail and watches the light sweep across the water until morning.", 9.8),
  summary(9.6, { status: "completed" }),
];

/// The first and last text lines of the answer that starts with `text`, and the column's edges.
function answerLine(doc: Document, text: string) {
  for (const node of doc.querySelectorAll<HTMLElement>(".acpmux-row .cv-md")) {
    if (!node.textContent?.startsWith(text)) continue;
    const rect = node.getBoundingClientRect();
    const column = node.closest(".acpmux-row")!.getBoundingClientRect();
    return { top: rect.top + 6, bottom: rect.bottom - 6, left: column.left, right: column.right };
  }
  return undefined;
}

/// The blank vertical rhythm between the two public answer fixtures.
function answerGap(doc: Document, above: string, below: string) {
  const first = answerLine(doc, above);
  const second = answerLine(doc, below);
  if (!first || !second) return undefined;
  return { x: (first.left + first.right) / 2, y: (first.bottom + second.top) / 2 };
}

/// Presses at `from` in the margin, drags to `to` in steps a frame apart, and lifts.
async function drag(ctx: PlayContext, from: { x: number; y: number }, to: { x: number; y: number }) {
  const doc = ctx.document;
  const view = doc.defaultView!;
  const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll")!;
  const init = (x: number, y: number, buttons: number): PointerEventInit => ({
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button: 0,
    buttons,
    isPrimary: true,
    pointerId: 1,
    pointerType: "mouse",
  });
  const target = doc.elementFromPoint(from.x, from.y) ?? scroller;
  target.dispatchEvent(new PointerEvent("pointerdown", init(from.x, from.y, 1)));
  for (let step = 1; step <= 6; step += 1) {
    const at = (a: number, b: number) => a + ((b - a) * step) / 6;
    view.dispatchEvent(new PointerEvent("pointermove", init(at(from.x, to.x), at(from.y, to.y), 1)));
    await new Promise((resolve) => view.requestAnimationFrame(resolve));
  }
  view.dispatchEvent(new PointerEvent("pointerup", init(to.x, to.y, 0)));
  await ctx.waitFor(() => !(view.getSelection()?.isCollapsed ?? true), { capMs: 1500 }).catch(() => undefined);
}

const gapVariants = Object.fromEntries(
  GAP_KINDS.flatMap((above) =>
    GAP_KINDS.map((below) => [
      `${above}-to-${below}-gap`,
      {
        note: `Drag from the gap between ${above} and ${below} rows; the nearest visible text caret starts a new native selection.`,
        snapshot: chat(gapPair(above, below), { title: "Select through transcript gaps" }),
        play: async (ctx: PlayContext) => {
          // Consecutive tools intentionally have no production row gap. This fixture supplies a
          // visible gap for that pair, as the midpoint browser regression does; content stays native.
          if (above === "tool" && below === "tool") {
            const style = ctx.document.createElement("style");
            style.textContent = '.acpmux-row[data-row-id="upper"] { padding-bottom: 32px; }';
            ctx.document.head.append(style);
          }
          for (const id of ["upper", "lower"]) {
            const selector = `[data-row-id="${id}"] .cv-tool.is-toggle`;
            if (ctx.document.querySelector(selector)) await ctx.click({ selector });
          }
          const rects = (id: string) => {
            const walker = ctx.document.createTreeWalker(ctx.document.querySelector(`[data-row-id="${id}"]`)!, 4);
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              if (!node.textContent?.startsWith(`${id} keeper`)) continue;
              const range = ctx.document.createRange();
              range.selectNodeContents(node);
              const boxes = Array.from(range.getClientRects());
              if (boxes.length) return boxes;
            }
            throw new Error(`No visible ${id} text`);
          };
          const after = rects("after")[0]!;
          const upper = ctx.document.querySelector<HTMLElement>('[data-row-id="upper"]')!;
          const column = upper.getBoundingClientRect();
          const padding = Number.parseFloat(ctx.document.defaultView!.getComputedStyle(upper).paddingBottom);
          await drag(
            ctx,
            { x: (column.left + column.right) / 2, y: column.bottom - Math.max(1, padding / 2) },
            { x: after.left + 180, y: after.top + after.height / 2 },
          );
          if (ctx.document.getSelection()?.isCollapsed) throw new Error("Gap drag selected no text");
        },
      },
    ]),
  ),
);

export default agentPaneEntry({
  id: "agent-pane.gutter-select",
  title: "Drag-select from the margin",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 900, normal: 1100, wide: 1280 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  variants: {
    ...gapVariants,
    "gaps-ready": {
      note: "Public agent message fixtures for the same before/after gap-selection capture; the pair variants also cover tools and prompts.",
      snapshot: chat(gapPair("agent", "agent"), { title: "Select through transcript gaps" }),
    },
    "from-left-margin": {
      note: "Pressed in the left margin beside the first answer and dragged down into the third: the selection runs from the start of the line beside the press through all three answers, as a document's margin selects.",
      snapshot: chat(rows, { title: "Drag-select from the margin" }),
      play: async (ctx) => {
        const first = answerLine(ctx.document, "Alpha");
        const third = answerLine(ctx.document, "Charlie");
        if (!first || !third || first.left < 40) return;
        await drag(ctx, { x: first.left / 2, y: first.top }, { x: third.left + 300, y: third.bottom });
      },
    },
    "from-right-margin": {
      note: "Pressed in the right margin beside the third answer and dragged up into the first: the selection runs back from the end of the line beside the press.",
      snapshot: chat(rows, { title: "Drag-select from the margin" }),
      play: async (ctx) => {
        const first = answerLine(ctx.document, "Alpha");
        const third = answerLine(ctx.document, "Charlie");
        if (!first || !third) return;
        const width = ctx.document.documentElement.clientWidth;
        if (width - third.right < 60) return;
        await drag(ctx, { x: (third.right + width - 16) / 2, y: third.bottom }, { x: first.left + 300, y: first.top });
      },
    },
    "from-row-gap": {
      note: "Pressed in the blank rhythm between the first two answers and dragged into the second: the nearest mounted caret starts the native range instead of leaving a dead zone.",
      snapshot: chat(rows, { title: "Drag-select from a row gap" }),
      play: async (ctx) => {
        const gap = answerGap(ctx.document, "Alpha", "Bravo");
        const second = answerLine(ctx.document, "Bravo");
        if (!gap || !second) return;
        await drag(ctx, gap, { x: second.left + 300, y: second.top + 4 });
      },
    },
  },
});
