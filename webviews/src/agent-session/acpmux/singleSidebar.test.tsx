import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // The diff viewer registers a custom element when App loads.
  customElements: dom.window.customElements,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
Object.assign(dom.window, { matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }) });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

test("the pane draws no session list of its own: agent chats live in the window's one sidebar", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void; command?(name: string): void };
  };
  const selected: unknown[] = [];
  host.cmuxAcpmuxActions = {
    ready: async () => ({ protocolVersion: 1, transport: "test" }),
    "chat.select": async (params) => {
      selected.push(params.sessionId);
    },
  };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await act(async () =>
      host.cmuxAcpmuxBridge!.receive({
        type: "snapshot",
        protocolVersion: 1,
        rows: [],
        connection: "connected",
        isWorking: false,
        queue: [],
        catalog: [],
        canLoadOlder: false,
        sessionId: "b",
        sessions: [
          { sessionId: "a", displayTitle: "First", cwd: "/src/web", updatedAt: 2 },
          { sessionId: "b", displayTitle: "Second", cwd: "/src/web", updatedAt: 1 },
        ],
      }),
    );
    // No rail, no list, no toggle that would open them: only the compact header.
    expect(container.querySelector(".acpmux-sidebar")).toBeNull();
    expect(container.querySelector(".acpmux-rail")).toBeNull();
    expect(container.querySelector(".acpmux-sidebar-toggle")).toBeNull();
    expect(container.querySelector(".acpmux-session-row")).toBeNull();
    expect(container.querySelector(".acpmux-header")).not.toBeNull();
    // Finding another chat goes through the command palette's chats page (decision K1, one
    // palette): the pane has no chat search of its own.
    await act(async () => host.cmuxAcpmuxBridge!.command!("searchChats"));
    expect(container.querySelector(".acpmux-search-layer")).toBeNull();
    expect(selected).toEqual([]);
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});
