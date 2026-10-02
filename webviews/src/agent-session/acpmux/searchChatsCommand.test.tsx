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
/// The pane width query. Starts narrow, so the session list is an overlay; `resize` flips it.
const media = { matches: true, addEventListener() {}, removeEventListener() {} };
Object.assign(dom.window, { matchMedia: () => media });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

test("the app's searchChats command toggles Search chats, and a pick selects the chat", async () => {
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
        sessions: [
          { sessionId: "s1", displayTitle: "Fix the checkout page", updatedAt: 2 },
          { sessionId: "s2", displayTitle: "Port the sidebar", updatedAt: 1 },
        ],
        connection: "connected",
        isWorking: false,
        queue: [],
        catalog: [],
        canLoadOlder: false,
      }),
    );
    expect(container.querySelector(".acpmux-search")).toBeNull();
    await act(async () => host.cmuxAcpmuxBridge!.command!("searchChats"));
    expect(container.querySelector(".acpmux-search")).not.toBeNull();
    const rows = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-search-row")];
    expect(rows.map((row) => row.querySelector(".acpmux-search-label")!.textContent)).toEqual([
      "Fix the checkout page",
      "Port the sidebar",
      "New chat",
    ]);
    await act(async () => rows[1]!.click());
    expect(selected).toEqual(["s2"]);
    expect(container.querySelector(".acpmux-search")).toBeNull();
    // A second command closes it again.
    await act(async () => host.cmuxAcpmuxBridge!.command!("searchChats"));
    await act(async () => host.cmuxAcpmuxBridge!.command!("searchChats"));
    expect(container.querySelector(".acpmux-search")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});

test("the palette names the app's Search chats shortcut as bound, and follows a rebind", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: {
      command?(name: string): void;
      applyShortcuts?(labels: Record<string, unknown>): void;
    };
  };
  host.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "test" }) };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const input = () => container.querySelector<HTMLInputElement>(".acpmux-search-input")!;
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await act(async () => host.cmuxAcpmuxBridge!.command!("searchChats"));
    // Before the host says, no shortcut is claimed.
    expect(input().title).toBe("Search chats");
    await act(async () => host.cmuxAcpmuxBridge!.applyShortcuts!({ "agentPane.searchChats": "⌘K" }));
    expect(input().title).toBe("Search chats (⌘K)");
    await act(async () => host.cmuxAcpmuxBridge!.applyShortcuts!({ "agentPane.searchChats": "⌥⌘P" }));
    expect(input().title).toBe("Search chats (⌥⌘P)");
    // Unbound in Settings: the host leaves the action out.
    await act(async () => host.cmuxAcpmuxBridge!.applyShortcuts!({}));
    expect(input().title).toBe("Search chats");
    // New chat starts one in this pane, which no app shortcut does, so it claims none.
    const newChat = [...container.querySelectorAll(".acpmux-search-row")].find(
      (row) => row.querySelector(".acpmux-search-label")!.textContent === "New chat",
    )!;
    expect(newChat.querySelector(".acpmux-search-kbd")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});
