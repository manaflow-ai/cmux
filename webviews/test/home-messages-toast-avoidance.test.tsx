// The app's toasts never cover the Messages compose bar, and the bar never moves for them (Leo,
// 2026-11-07: "The composer should never ever rise up because there's some sort of ... tooltip type
// thing"). The bar reports its box to the host (`cmux.home.messages.toastAvoidance {rects}`, viewport
// CSS pixels; detailHost.ts `homeToastAvoidance` over toastAvoidance.ts), which lifts its toasts above
// it (HomePageToastAvoidance.swift). Measured on mount, sent again only when it changes, cleared on unmount.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { PageClient } from "../src/pages/shared/pageClient";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
/** The bar's drawn box (none: it takes no room), and the resize observers' callbacks. */
let bar: { left: number; top: number; width: number; height: number } | undefined;
const resized: (() => void)[] = [];
/** The frames the page asked for; the test draws them (`draw`), so no test waits a fixed time. */
const frames: ((time: number) => void)[] = [];
let drawn = 0;

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const frame = (run: (time: number) => void) => frames.push(run);
  Object.assign(dom.window, {
    ResizeObserver: class {
      constructor(callback: () => void) {
        resized.push(callback);
      }
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: frame,
    cancelAnimationFrame: (id: number) => void (frames[id - 1] = () => {}),
  });
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const box = this.classList.contains("mt-compose") && bar ? bar : { left: 0, top: 0, width: 0, height: 0 };
    return { ...box, x: box.left, y: box.top, right: box.left + box.width, bottom: box.top + box.height } as DOMRect;
  };
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "MutationObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: frame,
    cancelAnimationFrame: (id: number) => void (frames[id - 1] = () => {}),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    MutationObserver: dom.window.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  bar = undefined;
  resized.length = 0;
  frames.length = 0;
  drawn = 0;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
const { DetailOps, homeToastAvoidance } = await import("../src/pages/home-messages/detail/detailHost");

const strings = createTranscriptStrings(["en"]);
/** Draws the frames asked for so far (the page measures in one), then lets the host's answers land. */
const settle = () =>
  act(async () => {
    while (drawn < frames.length) frames[drawn++]!(0);
    await Promise.resolve();
  });

/** A host that records the page's calls. */
function recordingHost() {
  const calls: { op: string; params: unknown }[] = [];
  const host: PageClient = {
    call: async <R,>(op: string, params: unknown) => {
      calls.push({ op, params });
      return null as R;
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  return { host, calls };
}

test("the compose bar's box goes to the host on mount, again only when it changes, and none on unmount", async () => {
  const container = installDom();
  const { host, calls } = recordingHost();
  const reports = homeToastAvoidance(host);
  bar = { left: 20.4, top: 660.6, width: 860, height: 90 };
  await act(async () => {
    root = createRoot(container);
    root.render(<MessageComposer strings={strings} sendEnabled onSend={async () => true} toastAvoidance={reports} />);
  });
  await settle();
  expect(calls).toEqual([
    { op: DetailOps.toastAvoidance, params: { rects: [{ left: 20, top: 661, right: 880, bottom: 751 }] } },
  ]);
  expect(DetailOps.toastAvoidance).toBe("cmux.home.messages.toastAvoidance");

  // A resize that leaves the box where it was sends nothing.
  await act(async () => resized.forEach((callback) => callback()));
  await settle();
  expect(calls.length).toBe(1);

  // The tray grew the bar upward: the new box goes.
  bar = { left: 20, top: 600, width: 860, height: 151 };
  await act(async () => resized.forEach((callback) => callback()));
  await settle();
  expect(calls.at(-1)).toEqual({
    op: DetailOps.toastAvoidance,
    params: { rects: [{ left: 20, top: 600, right: 880, bottom: 751 }] },
  });
  expect(calls.length).toBe(2);

  // The bar went (another conversation's page, a closed tab): the host avoids nothing.
  act(() => root!.unmount());
  root = undefined;
  expect(calls.at(-1)).toEqual({ op: DetailOps.toastAvoidance, params: { rects: [] } });
});

test("with no host the bar reports nothing, and a host that does not know the op ends the reports", async () => {
  const container = installDom();
  bar = { left: 0, top: 500, width: 400, height: 80 };
  await act(async () => {
    root = createRoot(container);
    root.render(<MessageComposer strings={strings} sendEnabled onSend={async () => true} />);
  });
  await settle();
  act(() => root!.unmount());

  let tries = 0;
  const older: PageClient = {
    call: async () => {
      tries += 1;
      throw new Error("cmux.protocol.unknown_op");
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const reports = homeToastAvoidance(older);
  await act(async () => {
    root = createRoot(container);
    root.render(<MessageComposer strings={strings} sendEnabled onSend={async () => true} toastAvoidance={reports} />);
  });
  await settle();
  expect(tries).toBe(1);
  bar = { left: 0, top: 400, width: 400, height: 180 };
  await act(async () => resized.forEach((callback) => callback()));
  await settle();
  expect(tries).toBe(1);
});
