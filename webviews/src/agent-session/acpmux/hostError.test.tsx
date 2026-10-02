import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// A pane whose host cannot hand it acpmux (not installed, or a daemon that will not start).
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
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
    "Node",
    "getSelection",
    "MutationObserver",
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
  customElements: dom.window.customElements,
  // The prompt is a Milkdown (ProseMirror) editor.
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
Object.assign(dom.window, {
  matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }),
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");
const { promptField, typeInto } = await import("./promptFieldTesting");

const HOST_ERROR = "acpmux did not start. Its log is at /tmp/acpmux/daemon.log.";
/// Lets the failed `ready` settle and Milkdown mount the prompt.
const settle = () => act(() => new Promise((resolve) => setTimeout(resolve, 20)));

test("a host that cannot start acpmux shows its error and a retry, and keeps what was typed", async () => {
  const host = dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  };
  let available = false;
  let readies = 0;
  host.cmuxAcpmuxActions = {
    ready: async () => {
      readies += 1;
      if (!available) throw new Error(HOST_ERROR);
      return { protocolVersion: 1, transport: "test" };
    },
  };
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const banner = () => document.querySelector(".acpmux-host-error");
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await settle();
    // The host's own words, whatever the failure, not a bare "Connecting".
    expect(banner()?.textContent ?? "(no error shown)").toContain(HOST_ERROR);
    const retry = banner()?.querySelector<HTMLButtonElement>("button");
    expect(retry?.textContent).toBe("Retry");

    // Nothing can take a prompt yet: Enter must not clear it.
    await act(async () => typeInto(promptField(document), "fix the build"));
    await act(async () => {
      document
        .querySelector("form")!
        .dispatchEvent(new dom.window.Event("submit", { bubbles: true, cancelable: true }));
    });
    expect(promptField(document).value).toBe("fix the build");

    // acpmux is installed now: Retry asks the host again at once, and the error goes away.
    available = true;
    const before = readies;
    await act(async () => retry!.click());
    expect(readies).toBe(before + 1);
    expect(banner()).toBeNull();
  } finally {
    await act(async () => root.unmount());
    delete host.cmuxAcpmuxActions;
  }
});
