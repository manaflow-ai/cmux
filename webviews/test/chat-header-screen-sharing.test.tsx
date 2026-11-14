import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "https://cmux.test/",
    pretendToBeVisual: true,
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = dom.window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  (await import("../src/agent-session/acpmux/native")).setNativeHost(undefined);
  await teardownDom(saved, { scope });
});

test("the New chevron reaches the current chat's screen sharing action without changing New", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { setNativeHost } = await import("../src/agent-session/acpmux/native");
  const { setHeaderState } = await import("../src/agent-session/acpmux/header/headerState");
  const calls: [string, Record<string, unknown>][] = [];
  setHeaderState({ headerControls: "trio" });
  window.localStorage.setItem("acpmux.header.newKind", "terminal");
  setNativeHost(async (method, params) => {
    calls.push([method, params]);
    return {};
  });
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ChatHeaderTools
        chat="session-123"
        controls="trio"
        onTerminal={() => undefined}
        onBrowser={() => undefined}
        summary={null}
        menu={() => []}
        newButton={{ available: {}, make: () => undefined }}
      />,
    ),
  );

  await act(async () => {
    (host.querySelector(".acpmux-header-new-more") as HTMLButtonElement).click();
  });
  const row = host.querySelector('[data-value="screen-sharing"]') as HTMLElement | null;
  expect(row).not.toBeNull();
  expect(row?.querySelector('[data-icon="remote.display"]')).not.toBeNull();
  await act(async () => row?.click());

  expect(calls).toEqual([["action.run", { id: "session.screenShare", session: "session-123" }]]);
  expect(window.localStorage.getItem("acpmux.header.newKind")).toBe("terminal");
});

test("the chevron has no screen sharing row when there is no chat session", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  await act(async () => root?.unmount());
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ChatHeaderTools
        controls="trio"
        onTerminal={() => undefined}
        onBrowser={() => undefined}
        summary={null}
        menu={() => []}
        newButton={{ available: {}, make: () => undefined }}
      />,
    ),
  );
  await act(async () => {
    (host.querySelector(".acpmux-header-new-more") as HTMLButtonElement).click();
  });
  expect(host.querySelector('[data-value="screen-sharing"]')).toBeNull();
});
