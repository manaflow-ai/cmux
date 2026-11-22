// A tooltip narrows to its widest line and never wraps one more line for it (Leo, 2026-11-07: "why
// is this even so wide in the first place?").
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { fitTooltipWidth } from "./tooltipFit";

let dom: JSDOM | undefined;
afterEach(() => {
  dom?.window.close();
  dom = undefined;
});

/**
 * A tooltip whose text lays out as `lines` (each line's width) at any width of at least `wrapsBelow`
 * px, and one line more below it. Each line is 14 px tall.
 */
function tooltip(text: string, lines: number[], wrapsBelow: number) {
  dom = new JSDOM(`<!doctype html><body><div class="ui-title-tooltip"><span>${text}</span></div></body>`);
  const doc = dom.window.document;
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  tip.style.boxSizing = "border-box";
  tip.style.padding = "2px 8px";
  tip.style.borderWidth = "1px";
  tip.style.borderStyle = "solid";
  tip.style.maxWidth = "320px";
  const width = () => parseFloat(tip.style.width) || 320;
  tip.getBoundingClientRect = () => {
    const count = width() < wrapsBelow ? lines.length + 1 : lines.length;
    return {
      left: 0,
      top: 0,
      width: width(),
      height: count * 14 + 6,
      right: width(),
      bottom: count * 14 + 6,
    } as DOMRect;
  };
  doc.createRange = () =>
    ({
      selectNodeContents() {},
      detach() {},
      getClientRects: () => lines.map((line, index) => ({ left: 9, right: 9 + line, width: line, top: index * 14 })),
    }) as unknown as Range;
  return tip;
}

test("a wrapped tooltip narrows to its widest line, its padding and rim included", () => {
  // "Output 2.3K · fresh input 14 · cache reads 941.4K · cache" over "writes 5K", balanced into two
  // even lines: the box loses the room beside them.
  const tip = tooltip("Output 2.3K · fresh input 14 · cache reads 941.4K · cache writes 5K", [190, 176], 150);
  fitTooltipWidth(tip, 320);
  // 190 px of text, 8 + 8 px of padding, 1 + 1 px of rim, and a pixel against rounding.
  expect(tip.style.width).toBe("209px");
});

test("a short tooltip is as wide as its text", () => {
  const tip = tooltip("Copy response", [86], 0);
  fitTooltipWidth(tip, 320);
  expect(tip.style.width).toBe("105px");
});

test("a width that would wrap one more line is never kept", () => {
  const tip = tooltip("Open the pull request for this branch in the browser", [200, 120], 260);
  fitTooltipWidth(tip, 320);
  expect(tip.style.width).toBe("320px");
});

test("lines as wide as the tooltip leave it at its max width", () => {
  const tip = tooltip("A long label that fills the whole tooltip on each of its lines", [302, 300], 0);
  fitTooltipWidth(tip, 320);
  expect(tip.style.width).toBe("320px");
});

test("the max width is the tooltip's own when the caller gives none", () => {
  const tip = tooltip("Fork from here", [90], 0);
  tip.style.maxWidth = "240px";
  fitTooltipWidth(tip);
  expect(tip.style.width).toBe("109px");
});

/**
 * A shortcut tooltip ("Opus 5.5" then "⌃⌘M" on its keycap) as the browser lays it out: the keycap
 * floats to the box's end, so at any width its text sits at the far right edge, `keycap` px wide
 * with `gap` px before it and `reach` px into the end padding (a negative end margin).
 */
function shortcutTooltip(text: number, keycap: { width: number; gap: number; reach: number }) {
  dom = new JSDOM(
    `<!doctype html><body><div class="ui-title-tooltip"><span class="ui-tooltip-hint">⌃⌘M</span><span class="ui-tooltip-text">Opus 5.5</span></div></body>`,
  );
  const doc = dom.window.document;
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  tip.style.boxSizing = "border-box";
  tip.style.padding = "2px 8px";
  tip.style.borderWidth = "1px";
  tip.style.borderStyle = "solid";
  const hint = tip.querySelector<HTMLElement>(".ui-tooltip-hint")!;
  hint.style.marginLeft = `${keycap.gap}px`;
  hint.style.marginRight = `${-keycap.reach}px`;
  const width = () => parseFloat(tip.style.width) || 320;
  // One line while the text and the keycap fit beside each other.
  const fits = () => width() - 18 >= text + keycap.gap + keycap.width - keycap.reach;
  const height = () => (fits() ? 20 : 40);
  tip.getBoundingClientRect = () =>
    ({ left: 0, top: 0, width: width(), height: height(), right: width(), bottom: height() }) as DOMRect;
  // The keycap at the content box's end, past which it reaches into the padding.
  const hintLeft = () => width() - 9 + keycap.reach - keycap.width;
  hint.getBoundingClientRect = () =>
    ({
      left: hintLeft(),
      right: hintLeft() + keycap.width,
      width: keycap.width,
      top: 3,
      bottom: 17,
      height: 14,
    }) as DOMRect;
  doc.createRange = () => {
    let node: Node | undefined;
    return {
      selectNodeContents(target: Node) {
        node = target;
      },
      detach() {},
      getClientRects: () =>
        hint.contains(node ?? null)
          ? [
              {
                left: hintLeft() + 4,
                right: hintLeft() + keycap.width - 4,
                width: keycap.width - 8,
                top: 4,
                bottom: 16,
              },
            ]
          : [{ left: 9, right: 9 + text, width: text, top: 3, bottom: 17 }],
    } as unknown as Range;
  };
  return tip;
}

test("a tooltip with a shortcut is as wide as its text and keycap, never its max width (https://github.com/manaflow-ai/cmux/issues/49650)", () => {
  // "Opus 5.5" (54 px) then its keycap (36 px, 6 px after the text, 4 px into the end padding):
  // measured at the 320 px max width, the floated keycap sat at the far edge and the tooltip kept
  // all 320 px, wider than the model chip it names.
  const tip = shortcutTooltip(54, { width: 36, gap: 6, reach: 4 });
  fitTooltipWidth(tip, 320);
  // 54 + 6 + 36 - 4 px of content, 8 + 8 px of padding, 1 + 1 px of rim, and a pixel against rounding.
  expect(tip.style.width).toBe("111px");
});
