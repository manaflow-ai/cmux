// The page tells the App where its open popups are, so the native Session Info panel steps behind
// them (Leo, 2026-11-02: "layering issue the context should go over top of the session info"): an
// open composer popover (the context ring's card) reports its rect, and an empty list once it closes.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextRing } from "../../ComposerPickers";
import { reportOverlays, type OverlayRect } from "./overlays";

let dom: JSDOM | undefined;
let root: Root | undefined;
let stop: (() => void) | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // JSDOM lays nothing out: the card sits at the composer's left, 200 x 120 above the ring.
  const base = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (this.classList.contains("acpmux-context-card"))
      return { left: 40, top: 300, right: 240, bottom: 420, width: 200, height: 120, x: 40, y: 300 } as DOMRect;
    return base.call(this);
  };
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  stop?.();
  stop = undefined;
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

/// The reports as they come, and a promise for the next one: tests wait on the report, not a time.
function recorder() {
  const reports: OverlayRect[][] = [];
  const waiters: (() => void)[] = [];
  return {
    reports,
    post: (rects: OverlayRect[]) => {
      reports.push(rects);
      for (const resolve of waiters.splice(0)) resolve();
    },
    /// Resolves once a report arrives that `done` accepts.
    async until(done: (last: OverlayRect[] | undefined) => boolean) {
      while (!done(reports.at(-1)))
        await act(async () => {
          await new Promise<void>((resolve) => waiters.push(resolve));
        });
    },
  };
}

/// Two painted frames: the reporter measures on the frame after a change.
async function frames() {
  for (let i = 0; i < 2; i++)
    await act(async () => {
      await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    });
}

const CARD = { left: 40, top: 300, right: 240, bottom: 420, radius: 0 };

test("an open composer popover reports its rect, and an empty list once it closes", async () => {
  const container = installDom();
  const record = recorder();
  stop = reportOverlays(document, record.post);
  await act(async () => {
    root = createRoot(container);
    root.render(<ContextRing used={111_000} size={475_000} />);
  });
  const ring = container.querySelector<HTMLButtonElement>(".acpmux-context-ring")!;
  await frames();
  expect(record.reports).toEqual([]);

  await act(async () => ring.focus());
  await record.until((last) => last?.length === 1);
  expect(record.reports.at(-1)).toEqual([CARD]);

  await act(async () => {
    document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  await record.until((last) => last?.length === 0);
  expect(document.querySelector(".acpmux-context-card")).toBeNull();
  expect(record.reports.at(-1)).toEqual([]);
});

test("a popup already open when the panel shows is reported, and the stop clears it", async () => {
  const container = installDom();
  container.innerHTML = '<div class="ui-popup acpmux-context-card">menu</div>';
  const record = recorder();
  stop = reportOverlays(document, record.post);
  await record.until((last) => last !== undefined);
  expect(record.reports.at(-1)).toEqual([CARD]);
  stop();
  stop = undefined;
  expect(record.reports.at(-1)).toEqual([]);
});

test("a popup the App draws past the window's edge, or a hidden one, is not reported", async () => {
  const container = installDom();
  container.innerHTML =
    '<div class="ui-popup acpmux-context-card" data-escaped>escaped</div><div hidden><div class="ui-tooltip acpmux-context-card">hidden</div></div>';
  const record = recorder();
  stop = reportOverlays(document, record.post);
  await frames();
  expect(record.reports).toEqual([]);
});
