import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { watchOutputViewport } from "./outputViewport";

test("the bottom fade exists only while more output lies below the scroll position", () => {
  const { window } = new JSDOM("<pre></pre>");
  const node = window.document.querySelector("pre")!;
  let reads = 0;
  Object.defineProperties(node, {
    scrollHeight: {
      get: () => {
        reads++;
        return 600;
      },
    },
    clientHeight: { get: () => 160 },
  });
  const overflows: boolean[] = [];
  const stop = watchOutputViewport(node, (value) => overflows.push(value));
  try {
    expect(overflows).toEqual([true]);
    expect(reads).toBe(2);
    expect(node.hasAttribute("data-more-below")).toBe(true);
    reads = 0;
    node.scrollTop = 440;
    node.dispatchEvent(new window.Event("scroll"));
    expect(reads).toBe(1);
    expect(node.hasAttribute("data-more-below")).toBe(false);
    node.scrollTop = 100;
    node.dispatchEvent(new window.Event("scroll"));
    expect(node.hasAttribute("data-more-below")).toBe(true);
    stop();
    node.scrollTop = 440;
    node.dispatchEvent(new window.Event("scroll"));
    expect(node.hasAttribute("data-more-below")).toBe(true);
  } finally {
    stop();
    window.close();
  }
});

test("a short output has neither a bottom fade nor a spurious measured expansion", () => {
  const { window } = new JSDOM("<pre></pre>");
  const node = window.document.querySelector("pre")!;
  Object.defineProperties(node, {
    scrollHeight: { get: () => 80 },
    clientHeight: { get: () => 80 },
  });
  const values: boolean[] = [];
  const stop = watchOutputViewport(node, (value) => values.push(value));
  expect(node.hasAttribute("data-more-below")).toBe(false);
  expect(values).toEqual([false]);
  stop();
  window.close();
});

test("an expanded viewport remeasures after its content or width fits", async () => {
  const { window } = new JSDOM('<pre data-preview="all"></pre>', { pretendToBeVisual: true });
  const node = window.document.querySelector("pre")!;
  let height = 600;
  let viewport = 160;
  Object.defineProperties(node, {
    scrollHeight: { get: () => height },
    clientHeight: { get: () => viewport },
  });
  const values: boolean[] = [];
  const stop = watchOutputViewport(node, (value) => values.push(value));
  try {
    expect(values).toEqual([true]);
    height = 120;
    viewport = 200;
    node.setAttribute("data-wrap", "true");
    await Promise.resolve();
    await new Promise((done) => window.requestAnimationFrame(done));
    expect(values).toEqual([true, false]);
  } finally {
    stop();
    window.close();
  }
});

test("streamed tokens measure only their own output, once per frame", async () => {
  const { window } = new JSDOM("<main></main>", { pretendToBeVisual: true });
  const reads = Array.from({ length: 80 }, () => 0);
  const nodes = reads.map((_, index) => {
    const node = window.document.createElement("pre");
    Object.defineProperties(node, {
      scrollHeight: {
        get: () => {
          reads[index]!++;
          return 600;
        },
      },
      clientHeight: { get: () => 160 },
    });
    window.document.querySelector("main")!.append(node);
    return node;
  });
  const stops = nodes.map((node) => watchOutputViewport(node, () => {}));
  reads.fill(0);
  try {
    for (let token = 0; token < 50; token++) nodes[20]!.append(` token${token}`);
    await Promise.resolve();
    await new Promise((done) => window.requestAnimationFrame(done));
    expect(reads[20]).toBeGreaterThan(0);
    expect(reads[20]).toBeLessThanOrEqual(2);
    expect(reads.filter((_, index) => index !== 20).every((count) => count === 0)).toBe(true);
  } finally {
    for (const stop of stops) stop();
    window.close();
  }
});
