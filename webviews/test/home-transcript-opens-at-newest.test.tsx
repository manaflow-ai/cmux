// l10n-allow-file: test fixtures.
// A Home chat opens at its newest message and stays there until the reader scrolls
// (https://github.com/manaflow-ai/cmux/issues/34562), through `useTimelineWindow`, the virtual window
// both the Messages transcript and the channels timeline use. The person saw a Chief chat open
// partway up its history and had to scroll down. Two ways it happened, each driven here as the
// browser orders it (jsdom has no layout, so the scroller's sizes are the test's):
// - While a chat opens, the window's own pins leave scroll events queued. A row near the bottom
//   grows before the browser dispatches one (a code block's highlighting, a picture, a link card):
//   the event reads the scroller above the new bottom, as if the reader had scrolled up.
// - The scroller gets shorter with no scroll at all (the message box grows with a draft, a toast or
//   the pane takes room): the newest message slides under the fold.
// A scroll up by the reader still stops the following.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT", "HTMLElement", "Element", "Node", "Event", "ResizeObserver"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

/** The test's ResizeObserver: each instance's callback and what it observes, fired by hand. */
const observers = new Set<{ callback: ResizeObserverCallback; targets: Set<Element> }>();
class FakeResizeObserver {
  private readonly entry: { callback: ResizeObserverCallback; targets: Set<Element> };
  constructor(callback: ResizeObserverCallback) {
    this.entry = { callback, targets: new Set() };
    observers.add(this.entry);
  }
  observe(target: Element) {
    this.entry.targets.add(target);
  }
  unobserve(target: Element) {
    this.entry.targets.delete(target);
  }
  disconnect() {
    this.entry.targets.clear();
    observers.delete(this.entry);
  }
}

/** Delivers a size for `target` to every observer that watches it (none: nothing happens). */
function resized(target: Element, height: number) {
  for (const { callback, targets } of [...observers]) {
    if (!targets.has(target)) continue;
    const entry = { target, borderBoxSize: [{ blockSize: height, inlineSize: 600 }], contentRect: { height } };
    callback([entry as unknown as ResizeObserverEntry], {} as ResizeObserver);
  }
}

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    Event: dom.window.Event,
    ResizeObserver: FakeResizeObserver,
  });
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const ROW = 40;
const ROWS = 200;

/** A chat of ROWS rows in a scroller of `view.height`; `view.grown` is height the rows gained that
 * no observer has delivered yet. The scroller's scrollHeight is the window's total plus it. */
async function openChat() {
  const { createRoot } = await import("react-dom/client");
  const { useTimelineWindow } = await import("../src/pages/home-channels/useTimelineWindow");
  const view = { height: 600, grown: 0, total: 0 };
  const rows = Array.from({ length: ROWS }, (_, i) => ({ key: `row-${i}`, estimate: ROW }));
  let onScroll: () => boolean = () => false;

  function Chat() {
    const window = useTimelineWindow(rows, "conv_chief");
    view.total = window.total;
    onScroll = window.onScroll;
    return (
      <div ref={window.scroller} data-testid="scroller">
        <div style={{ height: window.total }}>
          {window.items.map((item) => (
            <div key={item.key} data-key={item.key} ref={window.measure} />
          ))}
        </div>
      </div>
    );
  }

  const host = document.getElementById("root")!;
  host.innerHTML = "";
  // The scroller's geometry, as a browser lays it out: scrollTop clamps to the bottom.
  let top = 0;
  const bottom = () => Math.max(0, view.total + view.grown - view.height);
  const root: Root = createRoot(host);
  await act(async () => root.render(<Chat />));
  const element = host.querySelector<HTMLElement>('[data-testid="scroller"]')!;
  Object.defineProperties(element, {
    clientHeight: { get: () => view.height, configurable: true },
    scrollHeight: { get: () => view.total + view.grown, configurable: true },
    scrollTop: {
      get: () => top,
      set: (value: number) => {
        top = Math.min(Math.max(0, value), bottom());
      },
      configurable: true,
    },
  });
  // The first pass ran before the sizes existed: rows measure as estimated, which runs the window again.
  await act(async () => {
    for (const row of element.querySelectorAll("[data-key]")) resized(row, ROW);
    resized(element, view.height);
  });
  const fromBottom = () => bottom() - top;
  const scrollEvent = async () => act(async () => void onScroll());
  const row = (index: number) => element.querySelector(`[data-key="row-${index}"]`)!;
  return { view, element, row, fromBottom, scrollEvent, setTop: (value: number) => (element.scrollTop = value), root };
}

test("a chat opens at its newest message", async () => {
  const chat = await openChat();
  expect(chat.fromBottom()).toBe(0);
  chat.root.unmount();
});

test("a row that grows before a queued scroll event arrives keeps the chat at its newest message", async () => {
  const chat = await openChat();
  expect(chat.fromBottom()).toBe(0);
  // The newest row's code block highlights 300 pt taller; the browser then dispatches the scroll
  // event the window's own pin queued, before the row's new height reaches the observer.
  chat.view.grown = 300;
  await chat.scrollEvent();
  // The observer delivers the row's height: the window lays out at it.
  chat.view.grown = 0;
  await act(async () => resized(chat.row(ROWS - 1), ROW + 300));
  expect(chat.fromBottom()).toBe(0);
  chat.root.unmount();
});

test("a scroller that gets shorter keeps the chat at its newest message", async () => {
  const chat = await openChat();
  expect(chat.fromBottom()).toBe(0);
  // The message box grows with a restored draft: the transcript's scroller is 150 pt shorter. A
  // shorter scroller changes no scroll position, so the browser sends no scroll event.
  chat.view.height = 450;
  await act(async () => resized(chat.element, 450));
  expect(chat.fromBottom()).toBe(0);
  chat.root.unmount();
});

test("the reader's scroll up stops the following, and rows that grow keep their place", async () => {
  const chat = await openChat();
  chat.setTop(3000);
  await chat.scrollEvent();
  const before = chat.element.scrollTop;
  chat.view.grown = 300;
  await chat.scrollEvent();
  chat.view.grown = 0;
  await act(async () => resized(chat.row(ROWS - 1), ROW + 300));
  expect(chat.element.scrollTop).toBe(before);
  expect(chat.fromBottom()).toBeGreaterThan(500);
  chat.root.unmount();
});

test("after the reader leaves the bottom, slow steps up or down never pull the chat back", async () => {
  const chat = await openChat();
  // One trackpad event past the near-bottom band (inside it the window keeps the chat at the bottom).
  chat.setTop(chat.element.scrollTop - 60);
  await chat.scrollEvent();
  expect(chat.fromBottom()).toBe(60);
  // Then a point at a time, up and back down: the chat stays where the reader puts it.
  for (let step = 0; step < 30; step += 1) {
    chat.setTop(chat.element.scrollTop - 1);
    await chat.scrollEvent();
  }
  for (let step = 0; step < 10; step += 1) {
    chat.setTop(chat.element.scrollTop + 1);
    await chat.scrollEvent();
  }
  expect(chat.fromBottom()).toBe(80);
  chat.root.unmount();
});
