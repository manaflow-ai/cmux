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
const media = {
  matches: false,
  listeners: new Set<() => void>(),
  addEventListener(_: string, listener: () => void) {
    media.listeners.add(listener);
  },
  removeEventListener(_: string, listener: () => void) {
    media.listeners.delete(listener);
  },
};
const resize = (wide: boolean) => {
  media.matches = wide;
  for (const listener of media.listeners) listener();
};
Object.assign(dom.window, { matchMedia: () => media });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

test("in a narrow pane the session overlay takes focus and closes on Escape, the scrim, or a pick", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void };
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
  const shell = () => container.querySelector(".acpmux-shell")!;
  const toggle = () => container.querySelector<HTMLButtonElement>(".acpmux-sidebar-toggle")!;
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
    // The main cmux sidebar already shows agent chats, so the pane's duplicate list starts closed.
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    expect(toggle().getAttribute("aria-expanded")).toBe("false");

    await act(async () => toggle().click());
    expect(shell().getAttribute("data-sidebar")).toBe("open");
    expect(toggle().getAttribute("aria-expanded")).toBe("true");
    expect(dom.window.document.activeElement?.textContent).toBe("Second");
    await act(async () => {
      dom.window.document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape" }));
    });
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    expect(dom.window.document.activeElement).toBe(toggle());

    await act(async () => toggle().click());
    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-sidebar-scrim")!.click());
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    expect(container.querySelector(".acpmux-sidebar-scrim")).toBeNull();
    expect(dom.window.document.activeElement).toBe(toggle());

    await act(async () => toggle().click());
    await act(async () =>
      [...container.querySelectorAll<HTMLButtonElement>(".acpmux-session-row")]
        .find((row) => row.textContent === "First")!
        .click(),
    );
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    expect(selected).toEqual(["a"]);
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});

test("a resize across the threshold resets the list and keeps the toggle in step", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  };
  host.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "test" }) };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const shell = () => container.querySelector(".acpmux-shell")!;
  const toggle = () => container.querySelector<HTMLButtonElement>(".acpmux-sidebar-toggle")!;
  try {
    media.matches = true;
    await act(async () => root.render(createElement(AcpmuxApp)));
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    // The optional list can still be opened beside the transcript, then closes when the pane narrows.
    await act(async () => toggle().click());
    expect(shell().getAttribute("data-sidebar")).toBe("open");
    await act(async () => resize(false));
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    // One click opens the overlay in the narrow pane.
    await act(async () => toggle().click());
    expect(shell().getAttribute("data-sidebar")).toBe("open");
    await act(async () => resize(true));
    expect(shell().getAttribute("data-sidebar")).toBe("closed");
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});

test("reopening the overlay with a leftover search that hides the selected row focuses the current view", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void };
  };
  host.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "test" }) };
  media.matches = false;
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const toggle = () => container.querySelector<HTMLButtonElement>(".acpmux-sidebar-toggle")!;
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
        sessionId: "a",
        sessions: [{ sessionId: "a", displayTitle: "First", cwd: "/src/web", updatedAt: 2 }],
      }),
    );
    await act(async () => toggle().click());
    const field = container.querySelector<HTMLInputElement>('input[aria-label="Search sessions"]')!;
    await act(async () => {
      // React's change events depend on what react-dom detected when another test file first
      // loaded it, and CI and local runs differ; call the field's onChange with its new value.
      field.value = "zzz";
      const props = Object.entries(field).find(([key]) => key.startsWith("__reactProps$"))![1];
      props.onChange({ target: field, currentTarget: field });
    });
    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-sidebar-scrim")!.click());
    expect(container.querySelector(".acpmux-session-row")).toBeNull();
    await act(async () => toggle().click());
    expect(dom.window.document.activeElement?.getAttribute("aria-label")).toBe("Sessions");
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});
