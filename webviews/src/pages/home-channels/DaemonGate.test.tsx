import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { LASTING_MS } from "../../ui/lasting";
import { DaemonGate, PAGE_LISTENER_REFUSED, type DaemonSource } from "./DaemonGate";
import { DaemonSocket } from "../shared/daemonSocket";
import { pageError } from "../shared/pageClient";
import { userMessage } from "../shared/userMessage";
import { settleReact } from "../../../test/support/domTeardown";

// Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD". While this build's Chief or the local
// daemon starts or restarts the Channels tab shows nothing; a connect that lasts past the grace is
// one muted line, never the red failure.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "sessionStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    // A test that installs a second DOM keeps the globals from before the first: saving again would
    // restore the closed first window, which the next test file then imports against.
    if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    sessionStorage: dom.window.sessionStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const strings = createStrings(
  {
    en: {
      "connect.title": "Connect to cmux",
      "connect.connecting": "Connecting…",
      "connect.failed": "Could not connect: %@",
      "connect.button": "Connect",
      "connect.restart": "Restart cmux-tui",
      "connect.listenerRefused": "This cmux-tui was started with its own sign-in settings. Restart cmux-tui.",
    },
  },
  ["en"],
);

/** A host whose daemon is still starting: every credential load is refused as retryable. */
const starting: DaemonSource = {
  kind: "host",
  load: () => Promise.reject(pageError("cmux.protocol.unavailable", "Starting this build's Chief…", true)),
};

test("a daemon still starting stays silent while automatic retries continue", async () => {
  const container = installDom();
  jest.useFakeTimers();
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <DaemonGate source={starting} strings={strings}>
        {() => null}
      </DaemonGate>,
    ),
  );
  await act(async () => void jest.advanceTimersByTime(LASTING_MS - 1));
  expect(container.textContent).toBe("");
  expect(container.querySelector("h1")).toBeNull();
  expect(container.querySelector(".hc-gate-error")).toBeNull();
  await act(async () => void jest.advanceTimersByTime(1));
  const lines = container.querySelectorAll(".hc-gate-line");
  expect(lines).toHaveLength(0);
  expect(container.textContent).toBe("");
  expect(container.querySelector(".hc-gate-error")).toBeNull();
  expect(container.querySelector("h1")).toBeNull();
});

test("a final refusal is said at once, as before", async () => {
  const container = installDom();
  root = createRoot(container);
  const blocked: DaemonSource = {
    kind: "host",
    load: () => Promise.reject(pageError("cmux.daemon.too_old", "Update cmux, then open this tab again.", false)),
  };
  await act(async () =>
    root!.render(
      <DaemonGate source={blocked} strings={strings}>
        {() => null}
      </DaemonGate>,
    ),
  );
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe("Update cmux, then open this tab again.");
});

/** Renders the gate on a host whose credential load always fails with `error`. */
async function renderBlocked(error: Error, restart?: () => void): Promise<HTMLElement> {
  const container = installDom();
  root = createRoot(container);
  const source: DaemonSource = { kind: "host", load: () => Promise.reject(error) };
  await act(async () =>
    root!.render(
      <DaemonGate source={source} strings={strings} restart={restart}>
        {() => null}
      </DaemonGate>,
    ),
  );
  return container;
}

test("a refused page listener says so plainly and offers Restart cmux-tui, never the daemon's text", async () => {
  let restarts = 0;
  const raw =
    "this daemon's WebSocket listener uses a configured credential (--ws-token or server.ws_token), so it has no credential file to share";
  const container = await renderBlocked(pageError(PAGE_LISTENER_REFUSED, raw, false), () => restarts++);
  const line = container.querySelector(".hc-gate-error")?.textContent ?? "";
  expect(line).toBe(strings.t("connect.listenerRefused"));
  expect(container.textContent).not.toContain("--ws-token");
  const buttons = [...container.querySelectorAll("button")].map((button) => button.textContent);
  expect(buttons).toEqual(["Restart cmux-tui"]);
  jest.useFakeTimers();
  await act(async () => container.querySelector("button")!.click());
  expect(restarts).toBe(1);
});

// Leo, 2026-11-22: "i dont know what kind of decision a "try again" would be other than "ok i guess ill
// click this."" A final refusal with no restart to offer keeps its sentence and asks again on its own,
// with no Connect to click, so the page opens once the person has done what the sentence says.
test("without the app to restart it, the refusal has no button", async () => {
  const container = await renderBlocked(pageError(PAGE_LISTENER_REFUSED, "--ws-token", false));
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe(strings.t("connect.listenerRefused"));
  expect(container.querySelectorAll("button").length).toBe(0);
});

test("any other final refusal is the plain sentence with no button", async () => {
  const container = await renderBlocked(
    pageError("cmux.page.failed", 'command(cmd: "ws-listen", code: Optional("io"))', false),
  );
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe(userMessage(undefined));
  expect(container.querySelectorAll("button").length).toBe(0);
});

test("a final refusal asks again on its own and opens once the daemon serves the page", async () => {
  const container = installDom();
  jest.useFakeTimers();
  let loads = 0;
  let fixed = false;
  const source: DaemonSource = {
    kind: "host",
    load: () => {
      loads++;
      return fixed
        ? Promise.reject(pageError("cmux.protocol.unavailable", "Starting this build's Chief…", true))
        : Promise.reject(pageError("cmux.daemon.too_old", "Update cmux, then open this tab again.", false));
    },
  };
  root = createRoot(container);
  await act(async () =>
    root!.render(
      <DaemonGate source={source} strings={strings}>
        {() => null}
      </DaemonGate>,
    ),
  );
  expect(loads).toBe(1);
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe("Update cmux, then open this tab again.");
  for (let ms = 0; ms < 5_000; ms += 100) await act(async () => void jest.advanceTimersByTime(100));
  expect(loads).toBeGreaterThan(1);
  // The person updated: the next ask leaves the refusal for the quiet connecting state.
  fixed = true;
  for (let ms = 0; ms < 35_000; ms += 100) await act(async () => void jest.advanceTimersByTime(100));
  expect(container.querySelector(".hc-gate-error")).toBeNull();
  expect(container.querySelectorAll("button").length).toBe(0);
});

/** When each credential load ran on a host whose daemon is down, at the longest jitter, for `forMs`. */
async function askTimes(visibility: "visible" | "hidden", forMs: number): Promise<number[]> {
  const container = installDom();
  Object.defineProperty(dom!.window.document, "visibilityState", { value: visibility, configurable: true });
  jest.useFakeTimers();
  const random = Math.random;
  Math.random = () => 1;
  const start = Date.now();
  const asks: number[] = [];
  const down: DaemonSource = {
    kind: "host",
    load: () => {
      asks.push(Date.now() - start);
      return Promise.reject(pageError("cmux.protocol.unavailable", "Starting this build's Chief…", true));
    },
  };
  try {
    root = createRoot(container);
    await act(async () =>
      root!.render(
        <DaemonGate source={down} strings={strings}>
          {() => null}
        </DaemonGate>,
      ),
    );
    for (let ms = 0; ms < forMs; ms += 100) await act(async () => void jest.advanceTimersByTime(100));
  } finally {
    Math.random = random;
  }
  return asks;
}

// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the f*** up and load
// faster/percievably load faster / whatever it takes". A shown Channels or Messages page whose daemon
// restarts asks again at least every 2 s, so it is back within 2 s of the daemon answering; its
// backoff went to 10 s, so a 10 s restart came back up to 5.5 s late. A hidden page keeps the 10 s step.
test("a shown page asks again at least every 2 s while its daemon is down; a hidden one backs off to 10 s", async () => {
  const shown = await askTimes("visible", 30_000);
  const gaps = shown.slice(1).map((at, index) => at - shown[index]!);
  expect(Math.max(...gaps)).toBeLessThanOrEqual(2_000);
  // From any moment the daemon comes back, the next ask is within 2 s.
  for (const up of [5_000, 10_000, 20_000]) {
    expect(shown.find((at) => at >= up)! - up).toBeLessThanOrEqual(2_000);
  }
  if (root) await act(async () => root!.unmount());
  root = undefined;
  jest.useRealTimers();
  await settleReact();
  dom?.window.close();
  const hidden = await askTimes("hidden", 30_000);
  const hiddenGaps = hidden.slice(1).map((at, index) => at - hidden[index]!);
  expect(Math.max(...hiddenGaps)).toBe(10_000);
});

test("a reconnect keeps the last conversation frame mounted without progress text", async () => {
  const container = installDom();
  jest.useFakeTimers();
  const closeListeners: ((reason: string) => void)[] = [];
  const daemon = {
    identity: { capabilities: ["ws-conversations-v1"] },
    onClose: (listener: (reason: string) => void) => {
      closeListeners.push(listener);
      return () => undefined;
    },
    close: () => undefined,
  } as unknown as DaemonSocket;
  const connect = jest.spyOn(DaemonSocket, "connect").mockResolvedValue(daemon);
  const source: DaemonSource = {
    kind: "host",
    load: () => Promise.resolve({ url: "ws://localhost:12345", token: "fixture" }),
  };
  try {
    root = createRoot(container);
    await act(async () =>
      root!.render(
        <DaemonGate source={source} strings={strings}>
          {() => <p data-cached-conversation>Last conversation</p>}
        </DaemonGate>,
      ),
    );
    const frame = container.querySelector("[data-cached-conversation]");
    expect(frame).not.toBeNull();
    await act(async () => {
      for (const closed of closeListeners) closed("disconnected");
    });
    expect(container.querySelector("[data-cached-conversation]")).toBe(frame);
    expect(container.textContent).toBe("Last conversation");
    expect(container.querySelector(".hc-gate-line")).toBeNull();
    await act(async () => void jest.advanceTimersByTime(500));
    expect(connect).toHaveBeenCalledTimes(2);
    // A successful replacement handshake keeps the subtree mounted too; its store can warm
    // while HomeStorePresentation keeps the cached frame until its first data arrives.
    expect(container.querySelector("[data-cached-conversation]")).toBe(frame);
  } finally {
    connect.mockRestore();
  }
});
