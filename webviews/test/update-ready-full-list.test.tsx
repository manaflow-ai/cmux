// The Update Ready card's hover popover scrolls to the update's whole change list (2026-10-20),
// with a fade at each edge that has more past it, and the shared super-thin card scroller.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
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
  // The list is the scroller and carries the shared card scroll style.
  expect(host.querySelector(".wn-pop-scroll")?.hasAttribute("data-cmux-card-scroll")).toBe(true);
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

// Leo 2026-11-05, on the hover card of an update across several nightlies: "this is too big ... i
// can't even scroll through the changes from that preview!" It listed the staged build's one change
// with its paragraph. The popover lists every build's changes, one line each, in a list that
// scrolls under a pinned heading and above a pinned See all changes.
test("the popover lists every build the update spans, one line each, in its own scroller", async () => {
  const { createRoot } = await import("react-dom/client");
  const { UpdateReadyHighlights } = await import("../src/pages/changelog/UpdateSurfaces");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/changelog/generated/strings.json")).default;
  const build = (n: number, title: string) => ({
    build: `42${n}`,
    shortVersion: `1.0.0-nightly.42${n}`,
    date: "2026-11-05",
    highlights: [{ id: `h${n}`, title, body: "", category: "new" as const }],
    changes: [],
  });
  const span = [
    build(3, "Go back to any recent version from What's New"),
    build(2, "Sidebar rows keep their color while dragged"),
    build(1, "Terminal tabs reopen in place"),
  ];
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <UpdateReadyHighlights
        data={{
          version: "1.0.0-nightly.4212118000001",
          build: "4212118000001",
          fromVersion: "1.0.0-nightly.4210546000001",
          fromBuild: "4210546000001",
          source: "whatsNew",
          language: "en",
          items: [
            {
              id: "rollback",
              title: "Go back to any recent version from What's New",
              summary:
                "What's New lists the recent builds; pick one and cmux installs it after the same checks as an update, then restarts.",
              category: "new",
            },
          ],
          rest: [],
          moreCount: 0,
          changelog: { from: "1.0.0-nightly.4210546000001", to: "1.0.0-nightly.4212118000001" },
        }}
        span={span}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined }}
      />,
    ),
  );
  const rows = [...host.querySelectorAll(".wn-pop-row .wn-pop-item")].map((row) => row.textContent);
  expect(rows).toEqual([
    "Go back to any recent version from What's New",
    "Sidebar rows keep their color while dragged",
    "Terminal tabs reopen in place",
  ]);
  // The heading and See all changes sit outside the scroller, so they stay while the list scrolls.
  const scroller = host.querySelector(".wn-pop-scroll")!;
  expect(scroller.hasAttribute("data-cmux-card-scroll")).toBe(true);
  expect(scroller.getAttribute("tabindex")).toBe("0");
  expect(scroller.querySelector(".wn-pop-title, .wn-pop-all")).toBeNull();
  expect(host.querySelector(".wn-pop")?.hasAttribute("data-cmux-card-scroll")).toBe(false);
  expect(host.querySelector(".wn-pop-title")?.textContent).toBe("nightly 4210546 → nightly 4212118");
  expect(host.querySelectorAll(".wn-pop-all")).toHaveLength(1);
  // No numbers: one line per change, its detail after the title.
  expect(host.querySelector(".wn-pop-n")).toBeNull();
  expect(host.querySelector(".wn-pop-row .wn-pop-line")?.textContent).toMatch(/^What's New lists the recent builds/);
});
