// l10n-allow-file: test fixtures.
// Leo 2026-10-20: switching tabs or workspaces and coming back to a New Tab page replayed its
// recent chats' entrance. A page you leave stays alive and hidden; its chat list keeps changing,
// and a change computed while it was hidden (a throttled render, a coalesced snapshot) lands as it
// shows again. The list diffed that against the frame from before the switch and faded or slid
// the rows on the first frame back. Switching away and back must make 0 fetches and start 0
// entrances (shared-projections.md); a change while the page shows still moves.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ChatCard } from "../src/agent-session/acpmux/newtab/screenModel";
import { pageSwitch, type PageSwitch } from "./support/pageSwitch";

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
let page: PageSwitch;
let root: Root | undefined;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  // The motion tokens the theme sets; jsdom resolves no custom properties.
  const tokens: Record<string, string> = {
    "--agent-motion-move": "0.2s",
    "--agent-motion-in": "0.15s",
    "--agent-ease-out": "ease-out",
  };
  const computed = window.getComputedStyle.bind(window);
  const getComputedStyle = (element: Element) =>
    new Proxy(computed(element), {
      get(target, property) {
        if (property === "getPropertyValue") return (name: string) => tokens[name] ?? target.getPropertyValue(name);
        if (property === "transform") return "none";
        const value = Reflect.get(target, property);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
  // Each card lays out one row lower than the one before it, so a card that changes slot moves.
  Object.assign(window.Element.prototype, {
    getBoundingClientRect(this: Element) {
      const host = this.parentElement;
      const index = host?.parentElement ? [...host.parentElement.children].indexOf(host) : 0;
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
  });
  const raf = (run: (time: number) => void) => setTimeout(() => run(0), 0) as unknown as number;
  Object.assign(window, { requestAnimationFrame: raf, cancelAnimationFrame: (id: number) => clearTimeout(id) });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle,
    requestAnimationFrame: raf,
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  page = pageSwitch(window);
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  page.reset();
});

afterAll(() => {
  page.dispose();
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

async function renderCards(cards: ChatCard[]) {
  const { ChatCards } = await import("../src/agent-session/acpmux/newtab/ChatCards");
  if (!root) {
    const { createRoot } = await import("react-dom/client");
    root = createRoot(window.document.getElementById("root")!);
  }
  await act(async () => root!.render(<ChatCards cards={cards} onOpen={() => {}} onShowAll={() => {}} />));
}

const chats = [card("a", "Fix the flaky upload test"), card("b", "Sidebar hover sticks"), card("c", "Release notes")];

test("back on a New Tab page, a chat list change that lands as it shows starts no entrance", async () => {
  await renderCards(chats);
  const seen = await page.switchAwayAndBack({
    // Another tab started a chat while this page was hidden.
    away: () => renderCards([card("n", "A chat another tab started"), ...chats.slice(0, 2)]),
    // The snapshot the hidden page coalesced lands as it shows: one more chat moved up.
    back: () => renderCards([card("c", "Release notes"), card("n", "A chat another tab started"), chats[0]]),
  });
  expect(seen).toEqual({ fetches: [], entrances: [] });
});

test("a chat that starts once the page has shown again still moves the chats under it", async () => {
  await renderCards(chats);
  await page.switchAwayAndBack();
  page.reset();
  await renderCards([card("m", "A chat started here"), ...chats.slice(0, 2)]);
  // The new chat itself appears at once (no entry animations on the New Tab); the rest slide.
  expect(page.entrances().some((entry) => entry.includes("A chat started here"))).toBe(false);
  expect(page.entrances().some((entry) => entry.includes("(transform)"))).toBe(true);
});

test("switching away and back reads no All chats page", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const row = (key: string, updatedAt: number) => ({ key, harness: "claude", title: key, cwd: "/tmp/cmux", updatedAt });
  const load = page.fetch("chats.page", async () => ({ chats: [row("a", 3), row("b", 2)], ready: true }));
  root = createRoot(window.document.getElementById("root")!);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(page.fetches()).toEqual(["chats.page"]);
  const seen = await page.switchAwayAndBack();
  expect(seen).toEqual({ fetches: [], entrances: [] });
});
