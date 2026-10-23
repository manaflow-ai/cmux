// A terminal opened from an agent tab (Ctrl-`) starts in the folder the tab shows (#22225): the
// page's `pane.context` names the started chat's folder, else the project picked before its
// first send, and on the New Tab page the folder its project chip names.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { paneContext } from "../src/agent-session/acpmux/paneContext";
import { noChat, session } from "../src/gallery/fixtures/acpmux";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
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
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};
const started = noChat([session({ sessionId: "s1", cwd: "/Users/you/src/started" })], { sessionId: "s1" });

test("a started chat's folder is the terminal's", () => {
  expect(paneContext(started, { draft: "/Users/you/src/other" }).cwd).toBe("/Users/you/src/started");
});

test("a chat not started yet names the project picked for its first send", () => {
  expect(paneContext(noChat(), { draft: "/Users/you/src/cmuxterm-hq" }).cwd).toBe("/Users/you/src/cmuxterm-hq");
});

test("the New Tab page's chip folder wins over the chat behind the page", () => {
  expect(paneContext(started, { shown: "/Users/you/src/cmuxterm-hq" }).cwd).toBe("/Users/you/src/cmuxterm-hq");
});

test("with no folder anywhere, the context names none", () => {
  expect(paneContext(noChat()).cwd).toBeUndefined();
});

test("the New Tab screen reports the folder its chip names, and none once it is gone", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const folder = createRef<string | undefined>();
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabScreen
        snapshot={noChat()}
        lastAgent="claude"
        cwd="/Users/you"
        startCwd="/Users/you/src/cmuxterm-hq"
        folderRef={folder}
        onAsk={noop}
        onOpen={noop}
        onSearch={noop}
        onShell={noop}
        onJump={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  expect(folder.current).toBe("/Users/you/src/cmuxterm-hq");
  act(() => root?.unmount());
  root = undefined;
  expect(folder.current).toBeNull();
});

test("the classic New Tab page reports its project", async () => {
  const { createRoot } = await import("react-dom/client");
  const { NewTabPage } = await import("../src/agent-session/acpmux/NewTabPage");
  const folder = createRef<string | undefined>();
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <NewTabPage
        snapshot={noChat()}
        cwd="/Users/you/src/cmuxterm-hq"
        folderRef={folder}
        onSubmit={noop}
        onOpenSession={noop}
        onShowAll={noop}
      />,
    ),
  );
  expect(folder.current).toBe("/Users/you/src/cmuxterm-hq");
});
