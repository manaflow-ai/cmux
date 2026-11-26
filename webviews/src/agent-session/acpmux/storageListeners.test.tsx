// The transcript view (conversation/transcriptView.ts) and the Background tasks request
// (backgroundTasks/openBackgroundTasks.ts) hear other pages through the window's `storage` event. Loading
// either module adds no listener: the first view or panel drawn adds one, the last one gone removes it.
// Another page's change is still read: as an event while one is drawn, and on the next read or draw
// while none is.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "../../../test/support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

/// `storage` listeners on globalThis, counted from when the file starts.
let storageListeners = 0;
const target = globalThis as unknown as {
  addEventListener: (type: string, ...rest: unknown[]) => void;
  removeEventListener: (type: string, ...rest: unknown[]) => void;
};
const realAdd = target.addEventListener;
const realRemove = target.removeEventListener;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
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
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = dom.window.document.getElementById("root")!;
  target.addEventListener = function (this: unknown, type: string, ...rest: unknown[]) {
    if (type === "storage") storageListeners++;
    return realAdd.call(this, type, ...rest);
  };
  target.removeEventListener = function (this: unknown, type: string, ...rest: unknown[]) {
    if (type === "storage") storageListeners--;
    return realRemove.call(this, type, ...rest);
  };
});

afterAll(async () => {
  if (root) await act(async () => root!.unmount());
  await settleReact();
  target.addEventListener = realAdd;
  target.removeEventListener = realRemove;
  dom.window.close();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
});

const VIEW_KEY = "cmux.acpmux.transcriptView";
const FOCUS_KEY = "cmux.acpmux.backgroundFocus";

/// Another page wrote `key`: storage changes, and this page hears an event only if it listens.
function otherPageWrites(key: string, value: unknown) {
  localStorage.setItem(key, JSON.stringify(value));
  const event = new Event("storage");
  Object.assign(event, { key });
  globalThis.dispatchEvent(event);
}

test("loading adds no storage listener; the first reader adds one, the last one gone removes it", async () => {
  const { useTranscriptView, transcriptViewOf, resetTranscriptViews } = await import("./conversation/transcriptView");
  const { useBackgroundFocus } = await import("./backgroundTasks/openBackgroundTasks");
  const { createRoot } = await import("react-dom/client");
  resetTranscriptViews();
  expect(storageListeners).toBe(0);

  // A request made by another page while no panel was drawn.
  otherPageWrites(FOCUS_KEY, { sessionId: "chat", toolCallId: "call-1", at: Date.now() });

  function Reader() {
    const view = useTranscriptView("chat");
    const focus = useBackgroundFocus("chat");
    return <p>{`${view} ${focus?.toolCallId ?? "none"}`}</p>;
  }
  root = createRoot(host);
  await act(async () => root!.render(<Reader />));
  expect(storageListeners).toBe(2);
  expect(host.textContent).toBe("normal call-1");

  // Drawn: another pane's change arrives as an event.
  await act(async () => otherPageWrites(VIEW_KEY, { chat: "verbose" }));
  expect(host.textContent).toBe("verbose call-1");

  await act(async () => root!.unmount());
  root = undefined;
  expect(storageListeners).toBe(0);

  // None drawn: no event is heard, and a read still sees another pane's change.
  otherPageWrites(VIEW_KEY, { chat: "thinking" });
  expect(transcriptViewOf("chat")).toBe("thinking");
  resetTranscriptViews();
});

test("a choice storage refused stays this page's, through another pane's change and a later save", async () => {
  const { useTranscriptView, transcriptViewOf, setTranscriptView, resetTranscriptViews } =
    await import("./conversation/transcriptView");
  const { createRoot } = await import("react-dom/client");
  resetTranscriptViews();
  // Storage is full for one write: chat A's choice is kept in this page only.
  const proto = Object.getPrototypeOf(localStorage) as Storage;
  const setItem = proto.setItem;
  proto.setItem = () => {
    throw new Error("QuotaExceededError");
  };
  try {
    setTranscriptView("a", "verbose");
  } finally {
    proto.setItem = setItem;
  }
  expect(transcriptViewOf("a")).toBe("verbose");

  function Reader() {
    return <p>{`${useTranscriptView("a")} ${useTranscriptView("b")}`}</p>;
  }
  root = createRoot(host);
  await act(async () => root!.render(<Reader />));
  expect(host.textContent).toBe("verbose normal");

  // Drawn: another pane saves chat B. Chat A keeps this page's choice.
  await act(async () => otherPageWrites(VIEW_KEY, { b: "thinking" }));
  expect(host.textContent).toBe("verbose thinking");

  // Storage works again: a choice for chat C saves, and chat A's choice is saved with it.
  await act(async () => setTranscriptView("c", "thinking"));
  expect(transcriptViewOf("a")).toBe("verbose");
  expect(JSON.parse(localStorage.getItem(VIEW_KEY)!)).toEqual({ b: "thinking", a: "verbose", c: "thinking" });

  await act(async () => root!.unmount());
  root = undefined;
  expect(transcriptViewOf("a")).toBe("verbose");
  resetTranscriptViews();
});
