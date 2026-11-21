// A Minimal New Tab page draws no chat cards, device chats or Recently Closed list, so a push of
// those costs it no render (Leo, 2026-11-18: "Why should non visible thing even affect the renderer
// thread anyways?"). The spare page and a tab's New Tab share the chat's renderer; before this, every
// device-chat or closed-tab push re-rendered each of them. The layouts that draw the lists still
// re-render on a push.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, Profiler } from "react";
import type { Root } from "react-dom/client";
import { manySessions, noChat } from "../src/gallery/fixtures/acpmux";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { resetDeviceChatsForTests, setDeviceChats } from "../src/agent-session/acpmux/newtab/deviceChats";
import { setRecentlyClosed } from "../src/agent-session/acpmux/newtab/recentlyClosed";
import type { ScreenTemplate } from "../src/agent-session/acpmux/newtab/templates";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
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
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  resetDeviceChatsForTests();
  setRecentlyClosed([]);
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

const noop = () => {};
const NOW = new Date(2026, 10, 18, 12, 0).getTime();

/// Renders the page and returns how many commits each push below caused.
async function commitsPerPush(template: ScreenTemplate) {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  let commits = 0;
  const root: Root = createRoot(host);
  await act(async () =>
    root.render(
      <Profiler id="nt" onRender={() => (commits += 1)}>
        <NewTabScreen
          template={template}
          now={NOW}
          snapshot={noChat(manySessions(12))}
          lastAgent="claude"
          cwd="/Users/you/src/atlas"
          projects={[{ cwd: "/Users/you/src/atlas", label: "atlas" }]}
          onCreate={noop}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={noop}
        />
      </Profiler>,
    ),
  );
  // Let mount-time effects settle before counting.
  await act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
  try {
    const counted = async (push: () => void) => {
      const before = commits;
      await act(async () => push());
      return commits - before;
    };
    return {
      device: await counted(() =>
        setDeviceChats([{ key: "claude:pushed", harness: "claude", title: "Pushed", updatedAt: NOW }]),
      ),
      closed: await counted(() =>
        setRecentlyClosed([{ id: "t1", kind: "terminal", title: "zsh", closedAt: NOW, available: true }]),
      ),
    };
  } finally {
    await act(async () => root.unmount());
  }
}

test("a Minimal page does not re-render on a device chat or closed tab push", async () => {
  expect(await commitsPerPush("minimal")).toEqual({ device: 0, closed: 0 });
});

test("a layout that draws the lists still re-renders on those pushes", async () => {
  const pushed = await commitsPerPush("threads");
  expect(pushed.device).toBeGreaterThan(0);
  expect(pushed.closed).toBeGreaterThan(0);
});
