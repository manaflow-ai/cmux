import { afterEach, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { markHeightFold } from "../src/agent-session/acpmux/conversation/fold";
import { FoldRide } from "../src/agent-session/acpmux/conversation/foldRide";

// Two folds playing at once in different rows: the lower folding row rides the upper fold's change
// too, or its body overlaps (or leaves a gap under) the row above until the fold ends (review of
// #39917: "a lower row retaining 40px when it needed 90px").

let window: Window | undefined;
const globals = globalThis as { HTMLElement?: unknown };
const realHTMLElement = globals.HTMLElement;
afterEach(() => {
  window?.close();
  window = undefined;
  globals.HTMLElement = realHTMLElement;
});

function transcript(count: number) {
  window = new Window();
  globals.HTMLElement = window.HTMLElement;
  const document = window.document as unknown as Document;
  const scroller = document.createElement("div");
  scroller.className = "acpmux-scroll";
  document.body.append(scroller);
  const list = document.createElement("div");
  scroller.append(list);
  const rect = (top: number, bottom: number) => ({ top, bottom, height: bottom - top }) as DOMRect;
  scroller.getBoundingClientRect = () => rect(0, 600);
  const rows: HTMLElement[] = [];
  for (let index = 1; index <= count; index += 1) {
    const row = document.createElement("div");
    row.className = "acpmux-row";
    row.dataset.rowId = `row-${index}`;
    row.setAttribute("aria-posinset", String(index));
    row.setAttribute("aria-setsize", "100");
    // Each row 100px tall from the view's top; the last reaches far past the view's end.
    row.getBoundingClientRect = () => rect((index - 1) * 100, index === count ? 3000 : index * 100);
    list.append(row);
    rows.push(row);
  }
  return rows;
}

test("a folding row under another fold rides that fold's change as it grows", () => {
  const rows = transcript(4);
  const [upper, , lower, last] = rows as [HTMLElement, HTMLElement, HTMLElement, HTMLElement];
  const placed = new Map<HTMLElement, number>(rows.map((row) => [row, 100]));
  const height = new Map(placed);
  const ride = new FoldRide({ placed: (row) => placed.get(row), height: (row) => height.get(row), finish: () => {} });
  markHeightFold(upper, 10_000);
  markHeightFold(lower, 10_000);

  height.set(upper, 140);
  expect(ride.ride([upper])).toBe(true);
  height.set(lower, 110);
  expect(ride.ride([lower])).toBe(true);
  // The upper fold keeps growing while the lower one holds still.
  height.set(upper, 190);
  expect(ride.ride([upper])).toBe(true);

  expect(lower.style.translate).toBe("0 90px");
  expect(last.style.translate).toBe("0 100px");
  expect(upper.style.translate).toBe("");
  ride.release();
  expect(lower.style.translate).toBe("");
  expect(last.style.translate).toBe("");
});
