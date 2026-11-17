// l10n-allow-file: the status copy is supplied by the pane's string table.
// The running turn's live line commits again with every streamed token of the reply above it, and
// almost every such commit draws the same words and counts. Its two layout effects (Thinking.tsx
// `useRollOutWidth`, `useCountGlide`) read the line's box on every commit: one getBoundingClientRect
// and one offsetLeft per count, each of which lays the page out in the middle of the commit, at a cost
// that grows with what the transcript holds (bench/transcript-replay.bench.ts PAIRED=1 PROFILE=1: the
// line's effect cost about 0.75 ms a token in a chat of 34,600 rows against 0.15 ms in a small chat;
// Leo, 2026-11-12: "infinite everything feels like nothing"). Here 10 and 40 commits of the same words
// read the line's layout the same number of times (none past the first), a commit with new words or a
// resized line reads it again, and a roll still cuts the old words at the width they were drawn at.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Thinking } from "./Thinking";
import { setChatDisplay } from "../chatDisplay";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
/// Layout reads from script: getBoundingClientRect and offsetLeft.
let reads = 0;
/// The ResizeObserver callbacks of the page, to report a resized line.
let observers: (() => void)[] = [];
const WORDS_WIDTH = 87;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const view = dom.window as unknown as Record<string, unknown>;
  view.ResizeObserver = class {
    private readonly callback: () => void;
    constructor(callback: () => void) {
      this.callback = callback;
    }
    observe() {
      observers.push(this.callback);
    }
    disconnect() {
      observers = observers.filter((each) => each !== this.callback);
    }
  };
  const proto = dom.window.HTMLElement.prototype;
  proto.getBoundingClientRect = function () {
    reads += 1;
    return { x: 0, y: 0, top: 0, left: 0, right: WORDS_WIDTH, bottom: 20, width: WORDS_WIDTH, height: 20 } as DOMRect;
  };
  Object.defineProperty(proto, "offsetLeft", {
    configurable: true,
    get() {
      reads += 1;
      return 0;
    },
  });
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
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  reads = 0;
  observers = [];
});

afterEach(async () => {
  act(() => root?.unmount());
  setChatDisplay({});
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

/// The line as a streamed token commits it: the same words, the same clock.
const line = (now = 1_000, doing?: string) =>
  doing === undefined ? (
    <Thinking since={0} now={() => now} />
  ) : (
    <Thinking since={0} now={() => now} doing={doing} doingAt={1} />
  );

function readsOver(commits: number): number {
  act(() => root!.render(line()));
  // The first commit of these words reads the line once; the watch's first report is the box it read.
  for (const each of observers) each();
  const before = reads;
  for (let index = 0; index < commits; index += 1) act(() => root!.render(line()));
  return reads - before;
}

test("commits that draw the same words read the line's layout no more over 40 than over 10: none", () => {
  const ten = readsOver(10);
  act(() => root!.unmount());
  root = createRoot(container);
  const forty = readsOver(40);
  console.log(`PER-UPDATE live line layout reads ${JSON.stringify({ ten, forty })}`);
  expect(forty).toBe(ten);
  expect(ten).toBe(0);
});

test("new words, or a resized line, read the line again", () => {
  act(() => root!.render(line()));
  for (const each of observers) each();
  let before = reads;
  act(() => root!.render(line(3_000)));
  // The clock moved to 3s: the words and the counts are read again.
  expect(reads - before).toBeGreaterThan(0);
  before = reads;
  act(() => root!.render(line(3_000)));
  expect(reads - before).toBe(0);
  // The column narrowed: the line's box changed, so the next commit reads it again.
  for (const each of observers) each();
  before = reads;
  act(() => root!.render(line(3_000)));
  expect(reads - before).toBeGreaterThan(0);
});

test("a roll after commits that read nothing still cuts the old words at the width they were drawn", () => {
  act(() => root!.render(line()));
  for (const each of observers) each();
  for (let index = 0; index < 5; index += 1) act(() => root!.render(line()));
  act(() => root!.render(line(1_000, "Read App.tsx")));
  const out = container.querySelector<HTMLElement>(".cv-roll-out");
  expect(out).not.toBeNull();
  expect(out!.style.width).toBe(`${WORDS_WIDTH}px`);
});
