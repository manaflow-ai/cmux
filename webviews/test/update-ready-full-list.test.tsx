// The Update Ready card's hover popover scrolls to the update's whole change list (2026-10-20),
// with a fade at each edge that has more past it, and the shared super-thin card scroller.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT", "Node", "Element"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let dom: JSDOM;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the popover lists every change of the update, not three and a count", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  const item = (n: number) => ({ id: `c${n}`, title: `Change ${n}`, summary: null, category: "new" as const });
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={{
          version: "1.0.0-nightly.3845050428001",
          build: "3845050428001",
          fromVersion: "1.0.0-nightly.3801702344901",
          fromBuild: "3801702344901",
          source: "summary",
          language: "en",
          items: [1, 2, 3].map(item),
          rest: [4, 5, 6, 7, 8, 9].map(item),
          moreCount: 6,
          changelog: { from: "1.0.0-nightly.3801702344901", to: "1.0.0-nightly.3845050428001" },
        }}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined }}
      />,
    ),
  );
  const text = host.textContent ?? "";
  for (let n = 1; n <= 9; n++) expect(text).toContain(`Change ${n}`);
  expect(text).not.toContain("6 more");
  // The popover is the scroller and carries the shared card scroll style.
  expect(host.querySelector(".wn-pop")?.hasAttribute("data-cmux-card-scroll")).toBe(true);
});

test("a card scroller marks each edge that has more content past it", async () => {
  const { scrollEdges, installScrollEdges } = await import("../src/scrollers");
  expect(scrollEdges({ scrollTop: 0, clientHeight: 100, scrollHeight: 300 })).toEqual({ above: false, below: true });
  expect(scrollEdges({ scrollTop: 100, clientHeight: 100, scrollHeight: 300 })).toEqual({ above: true, below: true });
  expect(scrollEdges({ scrollTop: 200, clientHeight: 100, scrollHeight: 300 })).toEqual({ above: true, below: false });
  expect(scrollEdges({ scrollTop: 0, clientHeight: 300, scrollHeight: 300 })).toEqual({ above: false, below: false });

  const el = dom.window.document.createElement("div");
  let top = 0;
  Object.defineProperty(el, "clientHeight", { value: 100 });
  Object.defineProperty(el, "scrollHeight", { value: 300 });
  Object.defineProperty(el, "scrollTop", { get: () => top });
  const stop = installScrollEdges(el);
  expect(el.hasAttribute("data-cmux-more-below")).toBe(true);
  expect(el.hasAttribute("data-cmux-more-above")).toBe(false);
  top = 200;
  el.dispatchEvent(new dom.window.Event("scroll"));
  expect(el.hasAttribute("data-cmux-more-below")).toBe(false);
  expect(el.hasAttribute("data-cmux-more-above")).toBe(true);
  stop();
});
