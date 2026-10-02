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
    "Node",
    "getSelection",
    "MutationObserver",
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
  // The composer's prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const media = { matches: true, addEventListener() {}, removeEventListener() {} };
Object.assign(dom.window, { matchMedia: () => media });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");
const { promptField, typeInto } = await import("./promptFieldTesting");

test("while Trust this folder? waits, the searchChats command opens nothing under it", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void; command?(name: string): void };
  };
  const sent: unknown[] = [];
  host.cmuxAcpmuxActions = {
    ready: async () => ({ protocolVersion: 1, transport: "test" }),
    "acp.trust.get": async ({ cwd }) => ({ cwd, level: "unknown" }),
    "chat.send": async ({ text }) => {
      sent.push(text);
    },
  };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await act(async () =>
      host.cmuxAcpmuxBridge!.receive({
        type: "snapshot",
        protocolVersion: 1,
        rows: [],
        sessionId: "s1",
        summary: { sessionId: "s1", cwd: "/work/new", turnCount: 0 },
        sessions: [{ sessionId: "s1", displayTitle: "New chat", updatedAt: 1 }],
        connection: "connected",
        isWorking: false,
        queue: [],
        catalog: [],
        canLoadOlder: false,
      } as AcpmuxSnapshot),
    );
    await settle();
    const prompt = promptField(dom.window.document);
    await act(async () => typeInto(prompt, "Fix the build"));
    await act(async () => {
      prompt.element.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
      );
    });
    await settle();
    expect(container.querySelector(".acpmux-trust")).not.toBeNull();
    await act(async () => host.cmuxAcpmuxBridge!.command!("searchChats"));
    expect(container.querySelector(".acpmux-search")).toBeNull();
    expect(sent).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});
