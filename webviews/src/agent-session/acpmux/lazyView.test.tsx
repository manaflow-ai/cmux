// lazyView.tsx: a screen out of the pane's first JavaScript still draws in its first frame once
// preloaded, and a mount that waited for its chunk keeps its state when the chunk lands.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { lazyView, preloadWhenIdle } from "./lazyView";
import { settleReact } from "../../../test/support/domTeardown";

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
  if (root) act(() => root?.unmount());
  await settleReact();
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function Screen({ label }: { label: string }) {
  const [count, setCount] = useState(0);
  return (
    <button type="button" onClick={() => setCount(count + 1)}>
      {label} {count}
    </button>
  );
}

test("a preloaded view draws in the same commit as its parent, with no empty frame", async () => {
  let loads = 0;
  const View = lazyView(async () => {
    loads += 1;
    return Screen;
  });
  await View.preload();
  await View.preload();
  expect(loads).toBe(1);
  const host = installDom();
  root = createRoot(host);
  // A synchronous commit: no promise settles between the render and the read.
  act(() => root!.render(<View label="History" />));
  expect(host.textContent).toBe("History 0");
});

test("a view mounted before its chunk shows nothing, then draws, and keeps its state after", async () => {
  let release!: (component: typeof Screen) => void;
  const View = lazyView(() => new Promise<typeof Screen>((resolve) => (release = resolve)));
  const host = installDom();
  root = createRoot(host);
  await act(async () => root!.render(<View label="Panel" />));
  expect(host.textContent).toBe("");
  await act(async () => release(Screen));
  expect(host.textContent).toBe("Panel 0");
  await act(async () => host.querySelector("button")!.click());
  // A re-render after the chunk landed keeps the same mount (no remount to the direct path).
  await act(async () => root!.render(<View label="Panel" />));
  expect(host.textContent).toBe("Panel 1");
});

test("a failed load is asked again, not kept as broken", async () => {
  let tries = 0;
  const View = lazyView(async () => {
    tries += 1;
    if (tries === 1) throw new Error("offline");
    return Screen;
  });
  await expect(View.preload()).rejects.toThrow("offline");
  await View.preload();
  expect(tries).toBe(2);
});

test("preloadWhenIdle loads each view once, in order, and stops; a cancel stops the rest", async () => {
  const order: string[] = [];
  const view = (name: string) => ({
    preload: async () => {
      order.push(name);
    },
  });
  for (const key of ["requestIdleCallback", "cancelIdleCallback"]) saved.set(key, scope[key]);
  const queued: (() => void)[] = [];
  const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
  // Runs every idle callback queued so far, then lets the preloads' promises settle.
  const runIdle = async () => {
    for (const run of queued.splice(0)) run();
    await flush();
  };
  scope.requestIdleCallback = (run: () => void) => queued.push(run);
  scope.cancelIdleCallback = (handle: number) => {
    queued[handle - 1] = () => undefined;
  };
  preloadWhenIdle([view("a"), view("b")]);
  // One view per idle moment: the second waits for the next.
  await runIdle();
  expect(order).toEqual(["a"]);
  await runIdle();
  expect(order).toEqual(["a", "b"]);
  await runIdle();
  expect(queued).toEqual([]);
  const cancel = preloadWhenIdle([view("c"), view("d")]);
  cancel();
  await runIdle();
  expect(order).toEqual(["a", "b"]);
});
