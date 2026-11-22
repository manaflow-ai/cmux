import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

// Lawrence 2026-10-09: "after cmd ctrl m we need to be focused in the 'type to search models'
// area". Cmd-Ctrl-M is the app's Switch Model… action (agentPane.switchModel): the host gives the
// page the keyboard and sends the `openModelPicker` command; the page opens the model picker on the
// path every opener uses, which ends with the keyboard in its search field.
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
    "Element",
    "customElements",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  // The diff viewer registers a custom element when App loads.
  customElements: dom.window.customElements,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  localStorage: { getItem: () => null, setItem: () => {} },
  IS_REACT_ACT_ENVIRONMENT: true,
});
Object.assign(dom.window, { matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }) });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");

test("the openModelPicker command opens the model picker with the keyboard in its search field", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
    cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void; command?(name: string): void };
  };
  host.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "test" }) };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await act(async () =>
      host.cmuxAcpmuxBridge!.receive({
        type: "snapshot",
        protocolVersion: 1,
        rows: [],
        sessions: [],
        connection: "connected",
        isWorking: false,
        queue: [],
        canLoadOlder: false,
        sessionId: "s",
        catalog: [
          {
            id: "claude",
            name: "Claude Code",
            models: [
              { id: "claude-opus-5-5", name: "Opus 5.5" },
              { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
            ],
          },
        ],
        summary: { sessionId: "s", harness: "claude", model: "claude-opus-5-5" },
      }),
    );
    expect(dom.window.document.querySelector(".acpmux-mp")).toBeNull();
    await act(async () => host.cmuxAcpmuxBridge!.command!("openModelPicker"));
    const menu = dom.window.document.querySelector(".acpmux-mp");
    expect(menu).not.toBeNull();
    const search = menu!.querySelector("input[role=combobox]");
    expect(search).not.toBeNull();
    expect(dom.window.document.activeElement).toBe(search);
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});
