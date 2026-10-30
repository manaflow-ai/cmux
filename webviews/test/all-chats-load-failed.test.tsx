// POLISH pass (cx-9br4q): when the chat index does not answer, All chats says it could not load and
// offers Try again, instead of an empty area that never fills.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.defineProperty(window.HTMLElement.prototype, "offsetHeight", { configurable: true, get: () => 800 });
  Object.defineProperty(window.HTMLElement.prototype, "offsetWidth", { configurable: true, get: () => 600 });
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a first page that fails says so, and Try again reads it again", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  let answer = false;
  let calls = 0;
  const load = async () => {
    calls += 1;
    if (!answer) throw new Error("daemon unavailable");
    return {
      chats: [{ key: "a", harness: "claude", title: "Fix the build", cwd: "/tmp/cmux", updatedAt: 1 }],
      ready: true,
    };
  };

  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  await act(async () => {});
  expect(host.textContent).toContain("Couldn't load your chats.");
  const retry = [...host.querySelectorAll("button")].find((button) => button.textContent === "Try again");
  expect(retry).toBeDefined();

  answer = true;
  const before = calls;
  await act(async () => retry!.click());
  await act(async () => {});
  expect(calls).toBe(before + 1);
  expect(host.textContent).not.toContain("Couldn't load your chats.");
});

test("a search that fails says so instead of leaving the unfiltered list under the query", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const load = async (params: { query?: string }) => {
    if (params.query) throw new Error("daemon unavailable");
    return {
      chats: [{ key: "a", harness: "claude", title: "Fix the build", cwd: "/tmp/cmux", updatedAt: 1 }],
      ready: true,
    };
  };
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  await act(async () => {});
  const input = host.querySelector<HTMLInputElement>(".nt-all-search input")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), "value")!.set!;
  await act(async () => {
    setValue.call(input, "build");
    input.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  await act(async () => {});
  expect(host.textContent).toContain("Couldn't load your chats.");
  expect(host.textContent).not.toContain("Fix the build");
});

test("a pending first page keeps the loaded row layout visible", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  let resolvePage:
    | ((page: { chats: { key: string; harness: string; title: string; updatedAt: number }[]; ready: boolean }) => void)
    | undefined;
  const load = () =>
    new Promise<{ chats: { key: string; harness: string; title: string; updatedAt: number }[]; ready: boolean }>(
      (resolve) => {
        resolvePage = resolve;
      },
    );

  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  await act(async () => {});
  expect(host.querySelectorAll(".nt-all-skeleton-row").length).toBeGreaterThan(0);
  expect(host.querySelector(".nt-chats-empty")).toBeNull();

  await act(async () =>
    resolvePage!({ chats: [{ key: "a", harness: "claude", title: "Fix the build", updatedAt: 1 }], ready: true }),
  );
  expect(host.querySelectorAll(".nt-all-skeleton-row")).toHaveLength(0);
  expect(host.textContent).toContain("Fix the build");
});

test("a first page that is still indexing keeps skeleton rows until the index is ready", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  let resolvePage: ((page: { chats: never[]; ready: boolean }) => void) | undefined;
  const load = () =>
    new Promise<{ chats: never[]; ready: boolean }>((resolve) => {
      resolvePage = resolve;
    });

  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  await act(async () => resolvePage!({ chats: [], ready: false }));
  expect(host.querySelectorAll(".nt-all-skeleton-row").length).toBeGreaterThan(0);
  expect(host.querySelector(".nt-chats-empty")).toBeNull();
});

test("the index scan completes to an empty state after a host push", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AllChatsList } = await import("../src/agent-session/acpmux/newtab/AllChatsList");
  const { setDeviceChats } = await import("../src/agent-session/acpmux/newtab/deviceChats");
  let ready = false;
  const load = async () => ({ chats: [], ready });
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<AllChatsList load={load} onOpen={() => {}} />));
  expect(host.querySelector(".nt-all-skeleton-row")).not.toBeNull();
  ready = true;
  await act(async () => setDeviceChats([]));
  expect(host.querySelector(".nt-all-skeleton-row")).toBeNull();
  expect(host.querySelector(".nt-chats-empty")).not.toBeNull();
});
