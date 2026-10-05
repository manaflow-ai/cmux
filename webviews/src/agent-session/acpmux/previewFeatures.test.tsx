import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
// WebKit has AnimationEvent. react-dom reads it once, when the first test file imports it, and
// without it listens for webkitAnimationEnd in every later file (searchChats.test.tsx).
(dom.window as unknown as Record<string, unknown>).AnimationEvent ??= dom.window.Event;
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

/// Preview features (Settings > Advanced > Labs, `labs.previewFeatures`, off by default): the
/// session coverage label and the sidebar's Pull requests placeholder show only once the app turns
/// them on, and leave again when it turns them off.
test("preview features stay hidden until the app turns them on", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void; applyPreview?(on: boolean): void };
  };
  host.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "test" }) };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const rail = () =>
    [...container.querySelectorAll<HTMLButtonElement>(".acpmux-rail-button")].map((button) =>
      button.getAttribute("aria-label"),
    );
  const coverage = () => container.querySelector(".acpmux-session-coverage");
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await act(async () =>
      host.cmuxAcpmuxBridge!.receive({
        type: "snapshot",
        protocolVersion: 1,
        sessionId: "s1",
        rows: [],
        sessions: [{ sessionId: "s1", displayTitle: "Fix the checkout page", updatedAt: 1 }],
        connection: "connected",
        isWorking: false,
        queue: [],
        catalog: [],
        canLoadOlder: false,
      }),
    );
    expect(container.querySelector(".acpmux-header")).not.toBeNull();
    expect(coverage()).toBeNull();
    expect(rail()).not.toContain("Pull requests");

    await act(async () => host.cmuxAcpmuxBridge!.applyPreview?.(true));
    expect(coverage()).not.toBeNull();
    expect(rail()).toContain("Pull requests");

    await act(async () => host.cmuxAcpmuxBridge!.applyPreview?.(false));
    expect(coverage()).toBeNull();
    expect(rail()).not.toContain("Pull requests");
  } finally {
    await act(async () => root.unmount());
  }
});
