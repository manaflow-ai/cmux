import { expect, test } from "bun:test";
import {
  clearScrollOrigin,
  layoutScrollTop,
  physicalScrollTop,
  retainScrollOrigin,
  SCROLL_ORIGIN_PROPERTY,
  scrollOrigin,
  writeAnchorScrollTop,
  type ScrollCoordinateNode,
} from "./scrollCoordinates";

function quantizedNode(initial = 100, limit = 1_000) {
  let physical = initial;
  let writes = 0;
  const css = new Map<string, string>();
  const node: ScrollCoordinateNode = {
    get scrollTop() {
      return physical;
    },
    set scrollTop(value) {
      writes += 1;
      physical = Math.max(0, Math.min(limit, Math.round(value)));
    },
    style: {
      setProperty: (name, value) => {
        css.set(name, value ?? "");
      },
      removeProperty: (name) => {
        const old = css.get(name) ?? "";
        css.delete(name);
        return old;
      },
    },
  };
  return { node, css, writes: () => writes };
}

test("one anchor write retains logical quarter pixels without accumulating an origin", () => {
  const { node, css, writes } = quantizedNode();
  let rowTop = 500;
  const visual = rowTop - node.scrollTop;
  const deltas = [...Array.from({ length: 100 }, () => 0.25), ...Array.from({ length: 100 }, () => -0.25)];
  for (const [index, delta] of deltas.entries()) {
    const desired = layoutScrollTop(node) + delta;
    rowTop += delta;
    writeAnchorScrollTop(node, desired);
    expect(writes()).toBe(index + 1);
    expect(rowTop + scrollOrigin(node) - node.scrollTop).toBe(visual);
    expect(Math.abs(scrollOrigin(node))).toBeLessThanOrEqual(0.5);
    expect(physicalScrollTop(node, layoutScrollTop(node))).toBe(node.scrollTop);
  }
  expect(node.scrollTop).toBe(100);
  expect(scrollOrigin(node)).toBe(0);
  expect(css.has(SCROLL_ORIGIN_PROPERTY)).toBe(false);
});

test("wheel movement preserves the origin and intentional navigation resets it", () => {
  const { node, css } = quantizedNode();
  writeAnchorScrollTop(node, 100.25);
  const before = layoutScrollTop(node);
  const origin = scrollOrigin(node);
  node.scrollTop -= 19;
  expect(layoutScrollTop(node) - before).toBe(-19);
  expect(scrollOrigin(node)).toBe(origin);
  expect(css.get(SCROLL_ORIGIN_PROPERTY)).toBe("-0.25px");
  clearScrollOrigin(node);
  expect(layoutScrollTop(node)).toBe(node.scrollTop);
  expect(physicalScrollTop(node, 200)).toBe(200);
  expect(css.has(SCROLL_ORIGIN_PROPERTY)).toBe(false);
});

test("a rounded follow end retains fractional remeasurement even without a physical write", () => {
  const { node, writes } = quantizedNode(205);
  let logicalEnd = 204.5;
  let rowTop = 92.5;
  retainScrollOrigin(node, logicalEnd);
  const visual = rowTop + scrollOrigin(node) - node.scrollTop;
  expect(visual).toBe(-112);
  expect(writes()).toBe(0);
  for (const delta of [0.25, 0.25, -0.5, -10.5, 10.5]) {
    logicalEnd += delta;
    rowTop += delta;
    node.scrollTop = Math.ceil(logicalEnd - 0.01);
    retainScrollOrigin(node, logicalEnd);
    expect(rowTop + scrollOrigin(node) - node.scrollTop).toBe(visual);
    expect(layoutScrollTop(node)).toBe(logicalEnd);
  }
});

test("large clamp residuals reset and coordinates do not leak between scrollers", () => {
  const first = quantizedNode();
  const second = quantizedNode();
  writeAnchorScrollTop(first.node, 100.25);
  expect(scrollOrigin(second.node)).toBe(0);
  expect(writeAnchorScrollTop(first.node, 2_000)).toBe(0);
  expect(scrollOrigin(first.node)).toBe(0);
  expect(first.css.has(SCROLL_ORIGIN_PROPERTY)).toBe(false);
});
