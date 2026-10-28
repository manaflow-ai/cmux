// The agent pane's handshake backoff rests while the page is hidden (MQ4b): a pane
// whose host has no daemon asks Swift for a handshake again only while it is shown. Hidden for a
// minute it asks nothing; the show asks once, at once (retryBackoff.ts).
import { afterAll, afterEach, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;
let visibility: DocumentVisibilityState = "visible";

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
  Object.defineProperty(dom.window.document, "hidden", { configurable: true, get: () => visibility === "hidden" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    location: dom.window.location,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    Element: dom.window.Element,
    Event: dom.window.Event,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.getOwnPropertyNames(dom.window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key))
      replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  Object.assign(dom.window, { matchMedia: replacements.matchMedia });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  jest.useRealTimers();
});

afterAll(() => {
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

const flush = () =>
  act(async () => {
    for (let turn = 0; turn < 20; turn += 1) await Promise.resolve();
  });

function setVisibility(next: DocumentVisibilityState) {
  visibility = next;
  dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
}

test("a hidden pane asks for no handshake for a minute; its show asks once", async () => {
  // Imported before the fake clock: the first import runs module code that may arm real timers.
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  let handshakes = 0;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: (message: { method: string }) => {
            if (message.method === "ready") handshakes += 1;
            return Promise.resolve(
              message.method === "ready"
                ? { ok: false, error: { code: "daemon.unavailable", message: "no daemon" } }
                : { ok: true, value: undefined },
            );
          },
        },
      },
    },
  });
  jest.useFakeTimers();
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await flush();
  expect(handshakes).toBe(1);

  // Shown, the backoff asks again (250 ms, then 500 ms).
  await act(async () => jest.advanceTimersByTime(250));
  await flush();
  expect(handshakes).toBe(2);

  setVisibility("hidden");
  for (let second = 0; second < 60; second += 1) {
    await act(async () => jest.advanceTimersByTime(1_000));
    await flush();
  }
  expect(handshakes).toBe(2);

  await act(async () => setVisibility("visible"));
  await flush();
  expect(handshakes).toBe(3);
});
