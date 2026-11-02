import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { LASTING_MS } from "../../ui/lasting";
import { DaemonGate, type DaemonSource } from "./DaemonGate";

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
    },
  },
  ["en"],
);

/** A host whose daemon is still starting: every credential load is refused as retryable. */
const starting: DaemonSource = {
  kind: "host",
  load: () => Promise.reject(Object.assign(new Error("Starting this build's Chief…"), { retryable: true })),
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
  expect(lines[0]!.textContent).toBe("Could not connect: Starting this build's Chief…");
  expect(container.querySelector(".hc-gate-error")).toBeNull();
  expect(container.querySelector("h1")).toBeNull();
});

test("a final refusal is said at once, as before", async () => {
  const container = installDom();
  root = createRoot(container);
  const blocked: DaemonSource = {
    kind: "host",
    load: () => Promise.reject(Object.assign(new Error("too old"), { retryable: false })),
  };
  await act(async () =>
    root!.render(
      <DaemonGate source={blocked} strings={strings}>
        {() => null}
      </DaemonGate>,
    ),
  );
  expect(container.querySelector(".hc-gate-error")?.textContent).toBe("Could not connect: too old");
});
