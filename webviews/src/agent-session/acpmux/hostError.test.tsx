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

type Actions = Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
const paneWindow = () => dom.window as unknown as { cmuxAcpmuxActions?: Actions; WebSocket?: unknown };
/// One short act, so each state React reaches between timers is rendered.
const tick = (ms = 10) => act(() => new Promise((resolve) => setTimeout(resolve, ms)));

test("the error stays up while a handshake's WebSocket fails to connect", async () => {
  const pane = paneWindow();
  const savedSocket = globals.WebSocket;
  // An endpoint the host handed out that nothing listens on: the socket errors a little later.
  class RefusedSocket {
    onopen: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onclose: (() => void) | null = null;
    onmessage: (() => void) | null = null;
    readyState = 0;
    constructor() {
      setTimeout(() => {
        this.readyState = 3;
        this.onerror?.();
        this.onclose?.();
      }, 40);
    }
    send() {}
    close() {}
  }
  globals.WebSocket = RefusedSocket;
  pane.WebSocket = RefusedSocket;
  let readies = 0;
  pane.cmuxAcpmuxActions = {
    ready: async () => {
      readies += 1;
      if (readies === 1) throw new Error(HOST_ERROR);
      return { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:9/", token: "t" };
    },
  };
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const banner = () => document.querySelector(".acpmux-host-error");
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await settle();
    expect(banner()).not.toBeNull();
    await act(async () => banner()!.querySelector("button")!.click());
    // Through the handshake and the refused socket, the card never goes away.
    const shown: boolean[] = [];
    for (let step = 0; step < 10; step += 1) {
      await tick();
      shown.push(banner() !== null);
    }
    expect(readies).toBe(2);
    expect(
      shown.every(Boolean)
        ? "always shown"
        : `hidden at steps ${shown
            .map((on, i) => (on ? "" : i))
            .join(" ")
            .trim()}`,
    ).toBe("always shown");
  } finally {
    await act(async () => root.unmount());
    delete pane.cmuxAcpmuxActions;
    globals.WebSocket = savedSocket;
    delete pane.WebSocket;
  }
});

test("Retry during an attempt already in flight runs a full attempt when that one ends", async () => {
  const pane = paneWindow();
  const calls: Record<string, unknown>[] = [];
  let finishInFlight: ((error: Error) => void) | undefined;
  pane.cmuxAcpmuxActions = {
    ready: (params) => {
      calls.push(params);
      // The first attempt fails; the automatic retry hangs until the test ends it.
      if (calls.length === 2) return new Promise((_, reject) => (finishInFlight = reject));
      return Promise.reject(new Error(HOST_ERROR));
    },
  };
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const retry = () => document.querySelector<HTMLButtonElement>(".acpmux-host-error button");
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await settle();
    // The automatic retry (250 ms backoff) is now in flight.
    await tick(300);
    expect(calls.length).toBe(2);
    await act(async () => retry()!.click());
    // The click is not dropped: the pane says it is retrying.
    expect(retry()?.textContent).toBe("Retrying…");
    expect(calls.length).toBe(2);
    await act(async () => finishInFlight!(new Error(HOST_ERROR)));
    await tick();
    // The queued retry runs at once, and it may start the daemon (not reconnect-only).
    expect(calls.length).toBe(3);
    expect(calls[2]).toEqual({});
    expect(retry()?.textContent).toBe("Retry");
  } finally {
    await act(async () => root.unmount());
    delete pane.cmuxAcpmuxActions;
  }
});

test("a host error is the page's first frame: the host stops covering the pane once it draws", async () => {
  const pane = paneWindow();
  let painted = 0;
  pane.cmuxAcpmuxActions = {
    ready: async () => Promise.reject(new Error(HOST_ERROR)),
    "pane.painted": async () => {
      painted += 1;
    },
  };
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () => root.render(createElement(AcpmuxApp)));
    await settle();
    expect(document.querySelector(".acpmux-host-error")?.textContent ?? "(no error shown)").toContain(HOST_ERROR);
    // The host keeps its loading state over the page until this report; a failed handshake
    // that never reported would leave the error hidden behind it.
    expect(painted).toBe(1);
  } finally {
    await act(async () => root.unmount());
    delete pane.cmuxAcpmuxActions;
  }
});
