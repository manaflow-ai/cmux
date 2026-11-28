import { expect, test } from "bun:test";
import { OFFSCREEN_ROW_CLASS, onceRendered } from "../conversation/offscreenRows";
import { drawnHeightOf } from "./drawnHeight";

test("an observer's placeholder is not a measurement until the row renders", () => {
  const node = Object.assign(new EventTarget(), {
    classList: { contains: (name: string) => name === OFFSCREEN_ROW_CLASS },
    getBoundingClientRect: () => {
      throw new Error("observer must not force layout");
    },
  }) as unknown as HTMLElement;
  const stop = onceRendered(node, () => {});
  expect(drawnHeightOf(node, 60)).toBeUndefined();
  const rendered = Object.assign(new Event("contentvisibilityautostatechange"), { skipped: false });
  node.dispatchEvent(rendered);
  expect(drawnHeightOf(node, 120)).toBe(120);
  expect(drawnHeightOf(node, 0)).toBe(0);
  stop();
});
