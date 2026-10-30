// l10n-allow-file: test fixtures.
// Leo 2026-10-19: opening many New Tabs in a row, the open animation bounced on New Tab pages that
// were already open. Each earlier New Tab page is parked hidden behind the new one, and its lists
// (Chats, Open Tabs, Recently Closed) still change while it is hidden. useListMotion started their
// slide and fade then; WebKit suspends a hidden page's animations (hidden-page animation
// suspension), so each one played when the page showed again. A hidden page now moves nothing:
// it draws its rows at their new places, and a change while it shows still moves.
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
let visibility: DocumentVisibilityState = "visible";
/// Every animation started, by card title.
const started: string[] = [];
/// The animations still running (not cancelled).
const running = new Set<string>();
/// What each started animation moves, as `title: properties` ("transform" is a slide, "opacity" a fade).
const kinds: string[] = [];

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.defineProperty(window.document, "visibilityState", { configurable: true, get: () => visibility });
  Object.defineProperty(window.document, "hidden", { configurable: true, get: () => visibility === "hidden" });
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
  // Each card lays out one row lower than the one before it, so a card that changes slot moves.
  Object.assign(window.Element.prototype, {
    getBoundingClientRect(this: Element) {
      const host = this.parentElement;
      const index = host ? [...host.parentElement!.children].indexOf(host) : 0;
      return {
        left: 0,
        top: index * 40,
        width: 300,
        height: 36,
        right: 300,
        bottom: index * 40 + 36,
        x: 0,
        y: index * 40,
      };
    },
    animate(this: Element, keyframes: Keyframe[]) {
      const title = this.querySelector(".nt-card-title")?.textContent ?? this.className;
      started.push(title);
      kinds.push(`${title}: ${Object.keys(keyframes[0] ?? {}).join(",")}`);
      running.add(title);
      const animation = {
        cancel() {
          running.delete(title);
          animation.oncancel?.();
        },
        finish() {},
        onfinish: null as null | (() => void),
        oncancel: null as null | (() => void),
      };
      return animation as unknown as Animation;
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
  visibility = "visible";
  started.length = 0;
  kinds.length = 0;
  running.clear();
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

async function setVisibility(next: DocumentVisibilityState) {
  visibility = next;
  await act(async () => {
    window.document.dispatchEvent(new window.Event("visibilitychange"));
  });
  // Shown again: its first frame back passes (shared/pageReveal.ts settles until then).
  if (next === "visible")
    await act(async () => {
      for (let frame = 0; frame < 2; frame += 1) await new Promise((resolve) => window.requestAnimationFrame(resolve));
    });
}

const chats = [card("a", "Fix the flaky upload test"), card("b", "Sidebar hover sticks"), card("c", "Release notes")];

test("a chat that starts while the page is hidden moves nothing, then or when it shows again", async () => {
  await render(chats);
  // Another New Tab opened over this one: the page is parked, hidden.
  await setVisibility("hidden");
  await render([card("n", "A chat another tab started"), ...chats.slice(0, 2)]);
  expect(started).toEqual([]);
  // Switching back to it: nothing replays, and the rows are where the new list put them.
  await setVisibility("visible");
  expect(started).toEqual([]);
  // A later change while it shows still moves: its places were kept while hidden.
  await render([card("m", "A chat started here"), card("n", "A chat another tab started"), chats[0]]);
  // The new chat is drawn in its place at once (no entry animations on the New Tab).
  expect(started).not.toContain("A chat started here");
  // The one under it slides from the place it was drawn at while hidden; a lost place would leave
  // it still.
  expect(kinds).toContain("A chat another tab started: transform");
});

test("a motion in flight when the page hides ends there, instead of finishing when it shows", async () => {
  await render(chats);
  await render([card("n", "A new chat"), ...chats.slice(0, 2)]);
  expect(running.size).toBeGreaterThan(0);
  await setVisibility("hidden");
  expect([...running]).toEqual([]);
});

test("on a page that shows, a new chat appears at once and the chats under it slide", async () => {
  await render(chats);
  await render([card("n", "A new chat"), ...chats.slice(0, 2)]);
  expect(started).not.toContain("A new chat");
  expect(kinds).toContain("Fix the flaky upload test: transform");
});
