import { afterEach, expect, jest, test } from "bun:test";
import { act, useEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { HomeStorePresentation } from "./HomeStorePresentation";
import type { HomeChannelsStore } from "./store";
import { settleReact } from "../../../test/support/domTeardown";

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

function pendingStore(name: string, ready: boolean, selected?: string) {
  let finish!: () => void;
  let reject!: (error: Error) => void;
  let loaded = ready;
  let error: string | undefined;
  let selectionRefused = false;
  let stops = 0;
  const listeners = new Set<() => void>();
  const started = ready
    ? Promise.resolve()
    : new Promise<void>((resolve, fail) => {
        finish = resolve;
        reject = fail;
      });
  const publish = () => {
    for (const listener of listeners) listener();
  };
  const store = {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0) stops++;
      };
    },
    start: () => started,
    select: async () => {
      if (selectionRefused) throw new Error("read failed");
    },
    getSnapshot: () => ({
      loading: !loaded,
      connection: loaded ? "online" : "connecting",
      error,
      selected,
      conversations: new Map(selected ? [[selected, {}]] : []),
      messages: loaded ? [name] : [],
    }),
  } as unknown as HomeChannelsStore;
  return {
    store,
    finish: () => {
      loaded = true;
      finish();
    },
    fail: () => {
      error = "read failed";
      reject(new Error(error));
    },
    recover: () => {
      loaded = true;
      error = undefined;
      selectionRefused = false;
      publish();
    },
    refuseSelection: () => {
      selectionRefused = true;
    },
    subscriptions: () => listeners.size,
    stops: () => stops,
  };
}

function Frame({ store }: { store: HomeChannelsStore }) {
  // Match the page's independent subscription while the presentation lease also warms the store.
  useEffect(() => store.subscribe(() => undefined), [store]);
  return <p data-frame>{store.getSnapshot().messages.join("")}</p>;
}

function View({ store, endpoint = "same" }: { store: HomeChannelsStore; endpoint?: string }) {
  return (
    <HomeStorePresentation key={endpoint} store={store}>
      {(shown) => <Frame store={shown} />}
    </HomeStorePresentation>
  );
}

test("a successful handshake keeps the prior frame until the replacement store has data", async () => {
  const container = installDom();
  root = createRoot(container);
  const old = pendingStore("Cached conversation", true);
  const next = pendingStore("Fresh conversation", false);
  await act(async () => root!.render(<View store={old.store} />));
  const frame = container.querySelector("[data-frame]");
  // The socket handshake succeeded, but its new store has not read the inbox/page yet.
  await act(async () => root!.render(<View store={next.store} />));
  expect(container.querySelector("[data-frame]")).toBe(frame);
  expect(container.textContent).toBe("Cached conversation");
  await act(async () => next.finish());
  expect(container.querySelector("[data-frame]")).toBe(frame);
  expect(container.textContent).toBe("Fresh conversation");
});

test("a different endpoint never inherits the previous endpoint's cached conversation", async () => {
  const container = installDom();
  root = createRoot(container);
  const old = pendingStore("Private conversation", true);
  const next = pendingStore("Other endpoint", false);
  await act(async () => root!.render(<View endpoint="first" store={old.store} />));
  await act(async () => root!.render(<View endpoint="second" store={next.store} />));
  expect(container.textContent).toBe("");
  expect(container.textContent).not.toContain("Private conversation");
});

test("swapping to a replacement never drops its final subscription or restarts it", async () => {
  const container = installDom();
  root = createRoot(container);
  const old = pendingStore("Cached", true);
  const next = pendingStore("Fresh", false);
  await act(async () => root!.render(<View store={old.store} />));
  await act(async () => root!.render(<View store={next.store} />));
  expect(next.subscriptions()).toBe(1);
  await act(async () => next.finish());
  expect(next.subscriptions()).toBe(2);
  expect(next.stops()).toBe(0);
  expect(container.textContent).toBe("Fresh");
  await act(async () => root!.unmount());
  root = undefined;
  expect(next.subscriptions()).toBe(0);
  expect(next.stops()).toBe(1);
});

test("a failed initial read stays cached and a later store update can complete the handoff", async () => {
  const container = installDom();
  root = createRoot(container);
  const old = pendingStore("Cached", true);
  const next = pendingStore("Recovered", false);
  await act(async () => root!.render(<View store={old.store} />));
  await act(async () => root!.render(<View store={next.store} />));
  await act(async () => next.fail());
  expect(container.textContent).toBe("Cached");
  await act(async () => next.recover());
  expect(container.textContent).toBe("Recovered");
});

test("a rejected selection keeps the cached frame until a later update succeeds", async () => {
  const container = installDom();
  root = createRoot(container);
  const old = pendingStore("Cached", true, "conversation");
  const next = pendingStore("Recovered", false, "conversation");
  next.refuseSelection();
  await act(async () => root!.render(<View store={old.store} />));
  await act(async () => root!.render(<View store={next.store} />));
  await act(async () => next.finish());
  expect(container.textContent).toBe("Cached");
  await act(async () => next.recover());
  expect(container.textContent).toBe("Recovered");
});
