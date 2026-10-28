// A run's dollar figure (Leo 2026-10-21: "whats the $ supposed to be? we're all using subrouter2
// anyways"). Claude Code reports what a turn would cost at pay-per-token API prices, even on a
// subscription or through a router, where nobody pays it. The run card shows tokens instead; the run
// sheet keeps the figure, labelled as API prices with a tooltip that says what it is.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { RunCard } from "../src/pages/home-channels/RunCard";
import { RunSheet } from "../src/pages/home-channels/RunSheet";
import table from "../src/pages/home-channels/generated/strings.json";
import { createStrings } from "../src/pages/shared/i18n";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const strings = createStrings(table, ["en"]);
const run = {
  id: "r1",
  conversation: "c1",
  author: "chief",
  status: "done",
  startedAt: 0,
  endedAt: 60_000,
  updatedAt: 60_000,
  rev: 1,
  stepCount: 2,
  turn: "t1",
  answers: [],
  usage: { input: 1_840, output: 612, cacheRead: 46_200 },
  costUsd: 0.0421,
};
const entry = { run: run as never, steps: [], complete: true };

async function render(container: HTMLElement, node: React.ReactNode) {
  await act(async () => {
    root = createRoot(container);
    root.render(node);
  });
}

test("the run card shows tokens, never a dollar figure", async () => {
  const container = installDom();
  await render(container, <RunCard entry={entry} strings={strings} onOpen={() => {}} onLoad={() => {}} />);
  const metas = [...container.querySelectorAll(".lg-run-meta")].map((meta) => meta.textContent);
  expect(metas).toEqual([strings.format("run.steps.many", "2"), strings.format("run.tokens", "49k")]);
  expect(container.querySelector(".lg-run-bar")?.textContent).not.toContain("$");
});

test("the run sheet labels its dollar figure as API prices and says what it is", async () => {
  const container = installDom();
  await render(
    container,
    <RunSheet entry={entry} people={new Map()} strings={strings} place="Chief" onClose={() => {}} onLoad={() => {}} />,
  );
  const cost = [...container.querySelectorAll(".lg-sheet-meta span")].find((span) => span.textContent?.includes("$"));
  expect(cost?.textContent).toBe(strings.format("run.cost", "$0.04"));
  expect(cost?.textContent).not.toBe("$0.04");
  expect(cost?.getAttribute("title")).toBe(strings.t("run.cost.hint"));
});
