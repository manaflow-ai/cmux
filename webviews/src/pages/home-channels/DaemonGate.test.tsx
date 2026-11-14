import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { LASTING_MS } from "../../ui/lasting";
import { DaemonGate, PAGE_LISTENER_REFUSED, type DaemonSource } from "./DaemonGate";
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
    saved.set(key, scope[key]);
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

test("a daemon still starting shows nothing, then one muted line once it lasts", async () => {
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
  expect(lines).toHaveLength(1);
  // The host words this one for the person; it is said as is.
  expect(lines[0]!.textContent).toBe("Starting this build's Chief…");
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

test("without the app to restart it, the refusal keeps Connect", async () => {
  const container = await renderBlocked(pageError(PAGE_LISTENER_REFUSED, "--ws-token", false));
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe(strings.t("connect.listenerRefused"));
  expect([...container.querySelectorAll("button")].map((button) => button.textContent)).toEqual(["Connect"]);
});

test("any other final refusal is the plain sentence with Connect", async () => {
  const container = await renderBlocked(
    pageError("cmux.page.failed", 'command(cmd: "ws-listen", code: Optional("io"))', false),
  );
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe(userMessage(undefined));
  expect([...container.querySelectorAll("button")].map((button) => button.textContent)).toEqual(["Connect"]);
});
