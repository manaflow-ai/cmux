// l10n-allow-file: the status copy is supplied by the pane's string table.
// The live line reads layout (its words' width for a roll, its counts' places for their glide) only
// when what it draws can have moved: a streamed chunk re-renders it with a new `quietKey` and
// `heardKey` and nothing else, and once read its boxes cost no forced layout per chunk.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, Profiler } from "react";
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

const counts: WorkingCounts = {
  agents: 0,
  commands: 2,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
};

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

const CALLS = 12;

// Each new call (a tool call's start or end) rolls the live line's words: the old ones roll out with the tail they
// were last drawn with, kept in the render that draws them (`useRoll`).
test("each new call's words roll in one commit, the old words rolling out with their drawn tail", () => {
  let commits = 0;
  const onRender = () => {
    commits += 1;
  };
  const call = (doing: string, index: number) => (
    <Profiler id="line" onRender={onRender}>
      {step(doing, index)}
    </Profiler>
  );
  act(() => root!.render(call("Read 0.ts", 0)));
  commits = 0;
  for (let index = 1; index <= CALLS; index++) act(() => root!.render(call(`Read ${index}.ts`, index)));
  const out = container.querySelector<HTMLElement>(".cv-roll-out");
  expect(out?.dataset.text).toBe(` ${CALLS - 1}.ts`);
  expect(out?.dataset.tail).toContain("2 commands");
  console.log(`PER-CALL live line commits: ${commits / CALLS}`);
  // One commit a call (13 for 12 at cmux#50032's head). Before it, the rolled-out tail was filled in by a layout
  // effect: a second synchronous commit on every new call, 2 a call, and the transcript's with it.
  expect(commits / CALLS).toBeLessThanOrEqual(1.25);
});
