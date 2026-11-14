// A hidden chat page keeps no transcript (CMUX-571, chat-pages-memory.bench.ts HIDDEN=1): every agent chat tab is
// its own page in one shared renderer, and a hidden one kept its whole drawn transcript. hiddenTranscript.ts lets
// it go once the page has been hidden DORMANT_AFTER_MS, reads the reader's place first, and draws it again inside
// the `visibilitychange` that shows the page, so the first frame shown already has it.
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import type { Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let visibility: "visible" | "hidden" = "visible";

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
});

afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

const { DORMANT_AFTER_MS, beforeTranscriptDormant, resetTranscriptDormancy, useTranscriptDormant } =
  await import("../src/agent-session/acpmux/hiddenTranscript");
const { createRoot } = await import("react-dom/client");

let root: Root | undefined;
afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  visibility = "visible";
  resetTranscriptDormancy();
  jest.useRealTimers();
});

function Pane() {
  const dormant = useTranscriptDormant();
  return dormant ? null : createElement("section", { id: "transcript" }, "Answer 100:");
}

function mount(): void {
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(createElement(Pane)));
}

const drawn = () => dom.window.document.getElementById("transcript") !== null;

function setVisibility(next: "visible" | "hidden"): void {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

test("a page hidden past the delay lets its transcript go", () => {
  jest.useFakeTimers();
  mount();
  expect(drawn()).toBe(true);
  act(() => setVisibility("hidden"));
  act(() => jest.advanceTimersByTime(DORMANT_AFTER_MS - 1));
  expect(drawn()).toBe(true);
  act(() => jest.advanceTimersByTime(1));
  expect(drawn()).toBe(false);
});

test("a tab passed over on the way to another keeps its transcript", () => {
  jest.useFakeTimers();
  mount();
  act(() => setVisibility("hidden"));
  act(() => jest.advanceTimersByTime(DORMANT_AFTER_MS / 2));
  act(() => setVisibility("visible"));
  act(() => jest.advanceTimersByTime(DORMANT_AFTER_MS * 2));
  expect(drawn()).toBe(true);
});

test("the reader's place is read while the transcript is still drawn", () => {
  jest.useFakeTimers();
  mount();
  const seen: boolean[] = [];
  const stop = beforeTranscriptDormant(() => seen.push(drawn()));
  act(() => setVisibility("hidden"));
  act(() => jest.advanceTimersByTime(DORMANT_AFTER_MS));
  stop();
  expect(seen).toEqual([true]);
  expect(drawn()).toBe(false);
});

test("showing the page draws the transcript within the show, before any frame", () => {
  jest.useFakeTimers();
  mount();
  act(() => setVisibility("hidden"));
  act(() => jest.advanceTimersByTime(DORMANT_AFTER_MS));
  expect(drawn()).toBe(false);
  // No act and no timer: the show itself commits it (flushSync), as the engine paints right after.
  setVisibility("visible");
  expect(drawn()).toBe(true);
});

test("the chat's snapshot keeps the copy written as the page hid, not the page without its transcript", async () => {
  jest.useFakeTimers();
  const { SNAPSHOT_WRITE_EVENT, noteChatTheme, watchChatSnapshot } =
    await import("../src/agent-session/acpmux/chatSnapshot/live");
  mount();
  noteChatTheme("dark");
  const puts: unknown[] = [];
  const stop = watchChatSnapshot(
    "chat",
    async (params) => {
      puts.push(params);
      return { kept: true };
    },
    dom.window.document,
  );
  try {
    act(() => setVisibility("hidden"));
    // The page hid with its transcript drawn: that copy is written.
    expect(puts.length).toBe(1);
    act(() => jest.advanceTimersByTime(DORMANT_AFTER_MS + 20_000));
    expect(drawn()).toBe(false);
    // Neither the transcript leaving (a change the writer sees) nor the host asking writes over it.
    dom.window.dispatchEvent(new dom.window.Event(SNAPSHOT_WRITE_EVENT));
    act(() => jest.advanceTimersByTime(20_000));
    expect(puts.length).toBe(1);
    setVisibility("visible");
    dom.window.dispatchEvent(new dom.window.Event(SNAPSHOT_WRITE_EVENT));
    expect(puts.length).toBe(2);
  } finally {
    stop();
  }
});
