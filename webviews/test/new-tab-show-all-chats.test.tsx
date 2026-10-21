// `sidebar.showChats` (Show All Chats on New Tab): All chats left the sidebar for the New Tab page
// (cx-n0i9), so the setting now says whether the page lists every chat. On, the Threads and
// Console styles list All chats; off, they list the recent chats only, as Cards and Default do.
// The host sends `allChats: false` in the page's handshake when the setting is off.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";

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
  "MutationObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true }).window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
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
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    MutationObserver: window.MutationObserver,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

test("the handshake carries Show All Chats off, and only off", () => {
  expect(newTabHost({ newTab: { kind: "agent", allChats: false } })?.allChats).toBe(false);
  expect(newTabHost({ newTab: { kind: "agent" } })?.allChats).toBeUndefined();
  expect(newTabHost({ newTab: { kind: "agent", allChats: true } })?.allChats).toBeUndefined();
});

async function threadsPage(allChats: boolean | undefined): Promise<{ listsAll: boolean; recentRows: number }> {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <NewTabScreen
          template="threads"
          snapshot={noChat(manySessions(8))}
          lastAgent="claude"
          loadChatsPage={async () => ({ chats: [], ready: true })}
          onOpenChat={noop}
          {...(allChats === undefined ? {} : { allChats })}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={noop}
        />,
      ),
    );
    const screen = host.querySelector<HTMLElement>(".nt-screen")!;
    return {
      listsAll: screen.dataset.allChats === "true",
      recentRows: host.querySelectorAll(".nt-cards .nt-card").length,
    };
  } finally {
    await act(async () => root.unmount());
  }
}

test("Threads lists All chats by default and the recent chats only when Show All Chats is off", async () => {
  const shown = await threadsPage(undefined);
  expect(shown.listsAll).toBe(true);
  expect(shown.recentRows).toBe(0);
  const off = await threadsPage(false);
  expect(off.listsAll).toBe(false);
  expect(off.recentRows).toBeGreaterThan(0);
});
