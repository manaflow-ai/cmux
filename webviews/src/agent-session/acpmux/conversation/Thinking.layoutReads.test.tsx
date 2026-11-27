// l10n-allow-file: the status copy is supplied by the pane's string table.
// The live line reads layout (its words' width for a roll, its counts' places for their glide) only
// when what it draws can have moved: a streamed chunk re-renders it with a new `quietKey` and
// `heardKey` and nothing else, and once read its boxes cost no forced layout per chunk.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { WorkingCounts } from "./workingForModel";
import { settleReact } from "../../../../test/support/domTeardown";
import { importWithDom } from "../../../../test/support/importWithDom";

// Loaded with a document in place: this file installs its own jsdom per test (import-order-lint).
const [{ Thinking }, { WorkingCountsContext }] = await importWithDom(() =>
  Promise.all([import("./Thinking"), import("./workingForModel")]),
);

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const reads = { rect: 0, left: 0 };
const WIDTH = 123;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  // Each change shown at once: the line's dwell (LINE_DWELL_MS) has its own tests in Thinking.test.tsx.
  dom.window.document.documentElement.dataset.liveDwell = "off";
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  reads.rect = 0;
  reads.left = 0;
  dom.window.Element.prototype.getBoundingClientRect = function () {
    reads.rect += 1;
    return { x: 0, y: 0, top: 0, left: 0, right: WIDTH, bottom: 20, width: WIDTH, height: 20 } as DOMRect;
  };
  Object.defineProperty(dom.window.HTMLElement.prototype, "offsetLeft", {
    configurable: true,
    get() {
      reads.left += 1;
      return 0;
    },
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

// The one part the line draws after its time: the page a background command serves (PreviewChip.tsx).
const counts: WorkingCounts = { preview: { url: "http://localhost:5173/", open: () => {} } };

const TOKENS = 40;

function writing(index: number) {
  return (
    <WorkingCountsContext.Provider value={counts}>
      <Thinking
        since={0}
        now={() => 2_400}
        liveState="writing"
        quietKey={`assistant:${index}`}
        quietAt={2_400}
        heardAt={2_400}
        heardKey={`3:assistant:${index}`}
        turnTotal
      />
    </WorkingCountsContext.Provider>
  );
}

test("streamed chunks under an unchanged line read no layout after the first commit", () => {
  act(() => root!.render(writing(0)));
  expect(container.querySelector(".cv-worked")?.textContent).toContain("Writing");
  expect(container.querySelectorAll(".cv-worked__count").length).toBe(1);
  expect(reads.rect).toBe(1);
  expect(reads.left).toBe(1);
  for (let index = 1; index <= TOKENS; index++) act(() => root!.render(writing(index)));
  // One read each at the mount; none for the TOKENS chunks after it (one per chunk before).
  expect(reads.rect).toBe(1);
  expect(reads.left).toBe(1);
});

function step(doing: string, index: number) {
  return (
    <WorkingCountsContext.Provider value={counts}>
      <Thinking since={0} now={() => 2_400} doing={doing} doingAt={1} heardKey={`k:${index}`} turnTotal />
    </WorkingCountsContext.Provider>
  );
}

test("a change of words reads the line again, and the old words still roll out at their drawn width", () => {
  act(() => root!.render(step("Read a.ts", 0)));
  for (let index = 1; index <= TOKENS; index++) act(() => root!.render(step("Read a.ts", index)));
  expect(reads.rect).toBe(1);
  act(() => root!.render(step("Read b.ts", TOKENS + 1)));
  expect(reads.rect).toBeGreaterThan(1);
  const out = container.querySelector<HTMLElement>(".cv-roll-out");
  expect(out).not.toBeNull();
  expect(out!.style.width).toBe(`${WIDTH}px`);
});

/// A ResizeObserver that reports when the test says, each observed box at `width` px wide (the words'
/// box) or 20 (the rest): the page's observer reports after the frame's layout, which a commit never
/// forces.
function fakeObserver() {
  const live = new Set<{ callback: ResizeObserverCallback; boxes: Set<Element>; self: ResizeObserver }>();
  class FakeResizeObserver {
    private readonly entry: { callback: ResizeObserverCallback; boxes: Set<Element>; self: ResizeObserver };
    constructor(callback: ResizeObserverCallback) {
      this.entry = { callback, boxes: new Set(), self: this as unknown as ResizeObserver };
      live.add(this.entry);
    }
    observe(box: Element) {
      this.entry.boxes.add(box);
    }
    unobserve(box: Element) {
      this.entry.boxes.delete(box);
    }
    disconnect() {
      this.entry.boxes.clear();
      live.delete(this.entry);
    }
  }
  const report = (width: number) =>
    act(() => {
      for (const { callback, boxes, self } of live) {
        const entries = [...boxes].map((target) => {
          const inlineSize = target.matches("output.cv-thinking") ? width : 20;
          return {
            target,
            borderBoxSize: [{ inlineSize, blockSize: 20 }],
            contentRect: { width: inlineSize, height: 20 },
          } as unknown as ResizeObserverEntry;
        });
        callback(entries, self);
      }
    });
  return { FakeResizeObserver, report };
}

function ticking(doing: string, since: number) {
  return (
    <WorkingCountsContext.Provider value={counts}>
      <Thinking since={since} now={() => 60_000} doing={doing} doingAt={1} heardKey={doing} turnTotal />
    </WorkingCountsContext.Provider>
  );
}

test("observed, the line reads no box for its roll-out width: its time ticks and its words roll at the reported width", () => {
  const { FakeResizeObserver, report } = fakeObserver();
  const had = scope.ResizeObserver;
  scope.ResizeObserver = FakeResizeObserver;
  try {
    // A fresh root, so the line connects the observer above.
    act(() => root!.unmount());
    root = createRoot(container);
    act(() => root!.render(ticking("Read a.ts", 0)));
    report(87);
    // Each tick of its time moved the line (before: one forced read of the words' box per tick).
    for (let second = 1; second <= TOKENS; second++) act(() => root!.render(ticking("Read a.ts", -second * 1_000)));
    expect(reads.rect).toBe(0);
    act(() => root!.render(ticking("Read b.ts", -(TOKENS + 1) * 1_000)));
    expect(reads.rect).toBe(0);
    const out = container.querySelector<HTMLElement>(".cv-roll-out");
    expect(out).not.toBeNull();
    expect(out!.style.width).toBe("87px");
  } finally {
    act(() => root!.unmount());
    root = undefined;
    if (had === undefined) delete scope.ResizeObserver;
    else scope.ResizeObserver = had;
  }
});
