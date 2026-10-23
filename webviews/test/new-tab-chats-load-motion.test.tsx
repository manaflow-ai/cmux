// l10n-allow-file: test fixtures.
// Leo 2026-10-18 (NEXT nightly): every New Tab page's Chats replayed its motion when a workspace
// switch showed it. A page draws the device chats the app pushes at once, then acpmux's session
// list lands and the live chats take the top slots under other keys; useListMotion slid and faded
// the whole list for what is a load. Only a real insert or removal (a row or two) moves.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ChatCard } from "../src/agent-session/acpmux/newtab/screenModel";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "ResizeObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let root: Root | undefined;
const animated: string[] = [];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  // The motion tokens the theme sets; jsdom resolves no custom properties.
  const tokens: Record<string, string> = {
    "--agent-motion-move": "0.2s",
    "--agent-motion-in": "0.15s",
    "--agent-ease-out": "ease-out",
  };
  const computed = window.getComputedStyle.bind(window);
  const getComputedStyle = (element: Element) => {
    const style = computed(element);
    return new Proxy(style, {
      get(target, property) {
        if (property === "getPropertyValue") return (name: string) => tokens[name] ?? target.getPropertyValue(name);
        if (property === "transform") return "none";
        const value = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
  };
  Object.assign(window.Element.prototype, {
    animate(this: Element) {
      animated.push(this.querySelector(".nt-card-title")?.textContent ?? this.className);
      return { cancel() {}, finish() {}, onfinish: null, oncancel: null } as unknown as Animation;
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  animated.length = 0;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const card = (sessionId: string, title: string): ChatCard => ({
  sessionId,
  title,
  harness: "claude",
  age: "1m",
  state: "idle",
});

async function render(cards: ChatCard[]) {
  const { ChatCards } = await import("../src/agent-session/acpmux/newtab/ChatCards");
  if (!root) {
    const { createRoot } = await import("react-dom/client");
    root = createRoot(window.document.getElementById("root")!);
  }
  await act(async () => root!.render(<ChatCards cards={cards} onOpen={() => {}} onShowAll={() => {}} />));
}

// The device chats the app pushes before acpmux answers.
const device = [
  card("claude-code:a", "Fix the flaky upload test"),
  card("claude-code:b", "Sidebar hover sticks"),
  card("claude-code:c", "New Tab chats shuffle"),
  card("claude-code:d", "Release notes"),
];

test("the session list landing under the device chats moves nothing", async () => {
  await render(device);
  expect(animated).toEqual([]);
  // acpmux's sessions: two live chats take the top, the same chats' device rows drop out.
  await render([
    card("lane-1", "Sidebar hover sticks"),
    card("lane-2", "New Tab chats shuffle"),
    card("claude-code:a", "Fix the flaky upload test"),
    card("claude-code:d", "Release notes"),
  ]);
  expect(animated).toEqual([]);
});

// One active chat: its session takes its device row's slot under another key. The same chat
// (its agent session id is the device key's tail) keeps its row, so nothing moves.
test("one session replacing its own device row moves nothing", async () => {
  const withIds = device.map((row) => ({ ...row, chatKey: row.sessionId, chatId: row.sessionId.slice(12) }));
  await render(withIds);
  await render([{ ...card("lane-1", "Fix the flaky upload test"), chatId: "a" }, ...withIds.slice(1)]);
  expect(animated).toEqual([]);
});

// No entry animations on the New Tab (Leo 2026-10-22): a new chat is drawn in its slot at once.
// (jsdom lays nothing out, so the rows under it have no distance to slide here.)
test("a chat that starts while the page shows appears at once", async () => {
  await render(device);
  await render([card("lane-9", "A new chat"), ...device.slice(0, 3)]);
  expect(animated).toEqual([]);
});
