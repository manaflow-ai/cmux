// The New Tab project card keeps the places it first drew its projects in while the page is in view (Leo,
// 2026-11-27: "when you open a new tab the shown projects switch weird the placements get weird"); a spare
// page adopted for the next tab places them again.
import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
// src/ loads after the DOM is in place (test/import-order-lint.test.ts).
const { EnvironmentCard } = await import("./StageCards");
const { NEW_TAB_ADOPT_EVENT } = await import("./adoption");
const { keepPlaces } = await import("../projectRepos");
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

const project = (cwd: string) => ({ cwd, label: cwd.slice(1) });

test("keepPlaces: shown rows keep their places, new rows go after them, gone rows leave", () => {
  const placed: string[] = [];
  expect(keepPlaces([project("/a"), project("/b")], placed).map((row) => row.cwd)).toEqual(["/a", "/b"]);
  expect(keepPlaces([project("/c"), project("/b"), project("/a")], placed).map((row) => row.cwd)).toEqual([
    "/a",
    "/b",
    "/c",
  ]);
  expect(keepPlaces([project("/c"), project("/a")], placed).map((row) => row.cwd)).toEqual(["/a", "/c"]);
});

test("the card's rows stay put as recency and the host's answer reorder its projects; an adopt places again", () => {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const shown = () =>
    [...host.querySelectorAll(".nt-stage-row .nt-stage-text")].map((row) => row.textContent);
  const draw = (order: string[]) =>
    act(() =>
      root.render(
        <EnvironmentCard projects={order.map(project)} noProject={false} onPick={() => {}} onNoProject={() => {}} />,
      ),
    );
  draw(["/a", "/b", "/c"]);
  expect(shown()).toEqual(["a", "b", "c"]);
  // A chat in /c works (it moves up by recency), and the host's answer adds /d first.
  draw(["/d", "/c", "/a", "/b"]);
  expect(shown()).toEqual(["a", "b", "c"]);
  draw(["/c", "/b", "/a", "/d"]);
  expect(shown()).toEqual(["a", "b", "c"]);
  // The spare page is adopted for a new tab: that opening draws the order of now.
  act(() => {
    dom.window.dispatchEvent(new dom.window.Event(NEW_TAB_ADOPT_EVENT));
  });
  draw(["/c", "/b", "/a", "/d"]);
  expect(shown()).toEqual(["c", "b", "a"]);
  act(() => root.unmount());
});
