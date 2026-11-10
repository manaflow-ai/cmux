import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { gridOrder, useWidgetsLive } from "./ExtensionWidgets";

test("the widget row follows the person's layout, then the rest in their default order", () => {
  const clock = "app:manaflow-ai/clock#cmux.newtab.widget/1";
  const prs = "app:samples/github-prs#cmux.newtab.widget/1";
  expect(gridOrder(["warmGreeting", "timer", clock, prs], [])).toEqual(["warmGreeting", "timer", clock, prs]);
  expect(gridOrder(["warmGreeting", "timer", clock, prs], [prs, "timer", clock])).toEqual([
    prs,
    "timer",
    clock,
    "warmGreeting",
  ]);
  // A layout entry nothing draws (an uninstalled app, a widget turned off) holds no place.
  expect(gridOrder(["quote", clock], ["app:gone/app#cmux.newtab.widget/1", clock])).toEqual([clock, "quote"]);
});

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let root: Root | undefined;
let dom: JSDOM | undefined;

afterEach(() => {
  act(() => root?.unmount());
  jest.useRealTimers();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function install(): { setHidden(hidden: boolean): void; host: HTMLElement } {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const doc = dom.window.document;
  let hidden = false;
  Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => (hidden ? "hidden" : "visible") });
  for (const key of ["window", "document", "HTMLElement", "Node", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) {
    saved.set(key, scope[key]);
  }
  scope.window = dom.window;
  scope.document = doc;
  scope.HTMLElement = dom.window.HTMLElement;
  scope.Node = dom.window.Node;
  scope.navigator = dom.window.navigator;
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  return {
    host: doc.getElementById("root")!,
    setHidden(next) {
      hidden = next;
      act(() => {
        doc.dispatchEvent(new dom!.window.Event("visibilitychange"));
      });
    },
  };
}

// A switch away and back makes no read (shared-projections.md): the widgets stay mounted through a
// short hide and end only once the page has been hidden for the grace (R1).
test("a quick switch keeps the widgets mounted; a long hide ends them", () => {
  jest.useFakeTimers();
  const page = install();
  const seen: boolean[] = [];
  function Probe() {
    seen.push(useWidgetsLive(30));
    return null;
  }
  root = createRoot(page.host);
  act(() => root!.render(<Probe />));
  expect(seen.at(-1)).toBe(true);
  page.setHidden(true);
  act(() => void jest.advanceTimersByTime(29));
  page.setHidden(false);
  act(() => void jest.advanceTimersByTime(60));
  expect(seen.every(Boolean)).toBe(true);
  page.setHidden(true);
  act(() => void jest.advanceTimersByTime(29));
  expect(seen.at(-1)).toBe(true);
  act(() => void jest.advanceTimersByTime(1));
  expect(seen.at(-1)).toBe(false);
  page.setHidden(false);
  expect(seen.at(-1)).toBe(true);
});
