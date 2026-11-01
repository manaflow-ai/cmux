import { afterEach, expect, jest, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { LASTING_MS, useLasting } from "./lasting";

// Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD". A link down or connecting on a launch
// shows nothing; only one that lasts past the grace is said. The grace runs on a clock the test moves.
let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
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

function Probe({ down, grace }: { down: boolean; grace?: number }) {
  const lasting = useLasting(down, grace);
  return <p>{lasting ? "disconnected" : ""}</p>;
}

test("a link down shows nothing within the grace and its state once it lasts", async () => {
  const container = installDom();
  jest.useFakeTimers();
  root = createRoot(container);
  await act(async () => root!.render(<Probe down />));
  expect(container.textContent).toBe("");
  await act(async () => void jest.advanceTimersByTime(LASTING_MS - 1));
  expect(container.textContent).toBe("");
  await act(async () => void jest.advanceTimersByTime(1));
  expect(container.textContent).toBe("disconnected");
  // Back up: hidden at once.
  await act(async () => root!.render(<Probe down={false} />));
  expect(container.textContent).toBe("");
});

test("a link that comes back within the grace never shows, and the next drop waits the whole grace", async () => {
  const container = installDom();
  jest.useFakeTimers();
  root = createRoot(container);
  await act(async () => root!.render(<Probe down />));
  await act(async () => void jest.advanceTimersByTime(LASTING_MS - 1_000));
  await act(async () => root!.render(<Probe down={false} />));
  await act(async () => root!.render(<Probe down />));
  await act(async () => void jest.advanceTimersByTime(LASTING_MS - 1));
  expect(container.textContent).toBe("");
  await act(async () => void jest.advanceTimersByTime(1));
  expect(container.textContent).toBe("disconnected");
});

test("a grace of 0 (the gallery's stage frames) shows the state at once", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => root!.render(<Probe down grace={0} />));
  expect(container.textContent).toBe("disconnected");
});
