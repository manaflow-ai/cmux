// The jump bar's current card follows the scroll, and every card gets a turn: the short cards at
// the end of a page, which can never scroll up to the reading line, share the last of the scroll.
import { expect, test } from "bun:test";
import { currentCard } from "./useCurrentCard";

const LINE = 100;
/** A page laid out at scrollTop 0: each card's top on the page, read at `scrollTop`. */
function at(scrollTop: number, maxScroll: number, layout: Record<string, number>) {
  const ids = Object.keys(layout);
  const tops = new Map(ids.map((id) => [id, layout[id]! - scrollTop]));
  return currentCard({ ids, tops, line: LINE, scrollTop, maxScroll });
}

/** Every card that is current somewhere on a one-pixel sweep of the whole scroll, in order. */
function sweep(maxScroll: number, layout: Record<string, number>) {
  const order: string[] = [];
  for (let scrollTop = 0; scrollTop <= maxScroll; scrollTop++) {
    const id = at(scrollTop, maxScroll, layout)!;
    if (order.at(-1) !== id) order.push(id);
  }
  return order;
}

test("a long page: a card is current once its top reaches the line", () => {
  const layout = { a: 120, b: 900, c: 1800, d: 2700 };
  expect(at(0, 3000, layout)).toBe("a");
  expect(at(799, 3000, layout)).toBe("a");
  expect(at(800, 3000, layout)).toBe("b");
  expect(at(1700, 3000, layout)).toBe("c");
});

test("short cards at the end each become current in turn, and the last at the end", () => {
  // The page scrolls 600, so d and e (tops past 700) never reach the line at 100.
  const layout = { a: 120, b: 400, c: 690, d: 760, e: 820 };
  expect(sweep(600, layout)).toEqual(["a", "b", "c", "d", "e"]);
  expect(at(600, 600, layout)).toBe("e");
});

test("a page that barely scrolls still gives every card a turn", () => {
  const layout = { a: 120, b: 300, c: 380, d: 440 };
  expect(sweep(30, layout)).toEqual(["a", "b", "c", "d"]);
  expect(at(0, 30, layout)).toBe("a");
});

test("each end card gets room when the page has it", () => {
  const layout = { a: 120, b: 1500, c: 1560, d: 1620 };
  const order: Record<string, number> = {};
  for (let scrollTop = 0; scrollTop <= 1300; scrollTop++) {
    const id = at(scrollTop, 1300, layout)!;
    order[id] = (order[id] ?? 0) + 1;
  }
  for (const id of ["b", "c"]) expect(order[id]!).toBeGreaterThanOrEqual(46);
  // ...and only the end of the scroll: a is current until then.
  expect(order.a).toBe(1300 - 96);
});

test("a page that does not scroll keeps the first card current", () => {
  expect(at(0, 0, { a: 120, b: 200, c: 260 })).toBe("a");
});
