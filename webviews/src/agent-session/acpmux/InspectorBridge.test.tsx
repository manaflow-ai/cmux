import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "customElements", "Node", "IntersectionObserver", "ResizeObserver", "requestAnimationFrame", "cancelAnimationFrame", "IS_REACT_ACT_ENVIRONMENT", "getComputedStyle", "Element"].map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  IntersectionObserver: class { observe() {} unobserve() {} disconnect() {} },
  ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
Object.assign(dom.window, { matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) });
// App imports the changes view, whose web components reach for DOM classes by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter((key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals));
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => { Object.assign(globals, saved); for (const key of domClasses) delete globals[key]; });

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp, saveLogNatively } = await import("./App");

type Host = {
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  cmuxAcpmuxBridge?: { toggleInspector(open?: boolean): boolean };
  webkit?: { messageHandlers?: { agentSession?: { postMessage(message: { method: string; params: Record<string, unknown> }): unknown } } };
};
const host = dom.window as unknown as Host;

test("Show ACP Inspector toggles the inspector through the page bridge and reports its state", async () => {
  host.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "test" }) };
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const inspector = () => container.querySelector(".acpmux-inspector");
  const menuButton = () => container.querySelector<HTMLButtonElement>("button[aria-label='Chat actions']")!;
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    expect(inspector()).toBeNull();
    let open = false;
    await act(async () => { open = host.cmuxAcpmuxBridge!.toggleInspector(); });
    expect(open).toBe(true);
    expect(inspector()).not.toBeNull();

    // An explicit state is idempotent, and toggling again closes.
    await act(async () => { open = host.cmuxAcpmuxBridge!.toggleInspector(true); });
    expect(open).toBe(true);
    expect(inspector()).not.toBeNull();
    await act(async () => { open = host.cmuxAcpmuxBridge!.toggleInspector(); });
    expect(open).toBe(false);
    expect(inspector()).toBeNull();
    // The Chat actions menu and the native bridge share one state.
    await act(async () => menuButton().click());
    const menuItem = [...document.querySelectorAll<HTMLElement>("[role=menuitem]")].find((item) => item.textContent?.includes("ACP inspector"))!;
    expect(menuItem).toBeDefined();
    await act(async () => menuItem.click());
    await act(async () => { open = host.cmuxAcpmuxBridge!.toggleInspector(); });
    expect(open).toBe(false);
    expect(inspector()).toBeNull();
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});

test("a native save resolves saved, cancelled, or unavailable when the host cannot save", async () => {
  const posted: { method: string; params: Record<string, unknown> }[] = [];
  const reply = (value: unknown) => { host.webkit = { messageHandlers: { agentSession: { postMessage: (message) => { posted.push(message); return value; } } } }; };
  try {
    reply({ ok: true, value: true });
    expect(await saveLogNatively("{}\n", "acp-01234567-20261001-120000.jsonl")).toBe("saved");
    expect(posted.at(-1)).toMatchObject({ method: "pane.saveLog", params: { text: "{}\n", suggestedName: "acp-01234567-20261001-120000.jsonl" } });
    reply({ ok: true, value: false });
    expect(await saveLogNatively("{}\n", "acp.jsonl")).toBe("cancelled");
    reply({ ok: false, error: { code: "unsupported", userMessage: "Unsupported agent pane request: pane.saveLog" } });
    expect(await saveLogNatively("{}\n", "acp.jsonl")).toBe("unavailable");
    delete host.webkit;
    expect(await saveLogNatively("{}\n", "acp.jsonl")).toBe("unavailable");
  } finally {
    delete host.webkit;
  }
});
