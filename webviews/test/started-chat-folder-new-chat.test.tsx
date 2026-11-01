// Leo 2026-10-13: once a chat has a message its folder is fixed. The folder chip no longer moves
// the chat (a `cd` on its next prompt); choosing a folder, or New Chat Here, starts a new chat in
// that folder in a tab of its own, and this chat stays where it is.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "HTMLInputElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "PointerEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
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
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function mount(options: { onBrowseFolder?: () => Promise<string | undefined> } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const calls: { method: string; cwd: string }[] = [];
  const props = {
    started: true,
    summary: { sessionId: "chat", harness: "claude", cwd: "/work/app", host: "This Mac", hostKind: "local" },
    projectChoices: [
      { cwd: "/work/app", label: "app" },
      { cwd: "/work/site", label: "site" },
    ],
    onMove: (cwd: string) => calls.push({ method: "move", cwd }),
    onNewChat: (cwd: string) => calls.push({ method: "newChat", cwd }),
    ...(options.onBrowseFolder ? { onBrowseFolder: options.onBrowseFolder } : {}),
  } as unknown as Parameters<typeof ComposerContext>[0];
  root = createRoot(host);
  await act(async () => root!.render(<ComposerContext {...props} />));
  return calls;
}

const everywhere = () => [...dom.window.document.querySelectorAll<HTMLElement>("*")];

async function openFolder() {
  const button = host.querySelector<HTMLButtonElement>(".acpmux-location-button");
  expect(button, "the started chat's folder chip offers no menu").toBeTruthy();
  await act(async () => {
    button!.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    button!.click();
  });
}

test("choosing another folder in a started chat starts a new chat there, never a move", async () => {
  const calls = await mount();
  await openFolder();
  const site = everywhere().find(
    // The row names the folder; its path is the tooltip (hq#1957 composer location strip).
    (element) =>
      element.classList.contains("acpmux-menu-item") && element.querySelector('[title="/work/site"]') !== null,
  );
  expect(site, "the folder list is missing").toBeTruthy();
  // A real press: the row picks on its mousedown and the click that follows (detail 1) does not
  // pick again (ui/Combobox.tsx); a bare `click()` (detail 0) would be a second, separate pick.
  await act(async () => {
    site!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1 }));
    site!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, button: 0, detail: 1 }));
  });
  expect(calls).toEqual([{ method: "newChat", cwd: "/work/site" }]);
});

test("a started chat's folder menu offers New Chat Here in its own folder", async () => {
  const calls = await mount();
  await openFolder();
  const here = everywhere().find(
    (element) => element.tagName === "BUTTON" && element.textContent?.trim() === "New Chat Here",
  );
  expect(here, "no New Chat Here").toBeTruthy();
  await act(async () => here!.click());
  expect(calls).toEqual([{ method: "newChat", cwd: "/work/app" }]);
});

test("a late folder browse cannot create a chat after a newer folder pick", async () => {
  let resolveBrowse!: (cwd: string | undefined) => void;
  const calls = await mount({
    onBrowseFolder: () => new Promise<string | undefined>((resolve) => (resolveBrowse = resolve)),
  });
  await openFolder();
  const choose = everywhere().find(
    (element) => element.tagName === "BUTTON" && element.textContent?.trim() === "Choose folder…",
  );
  expect(choose, "no Choose folder action").toBeTruthy();
  await act(async () => choose!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 1 })));
  expect(resolveBrowse).toBeTypeOf("function");

  await openFolder();
  const site = everywhere().find(
    (element) =>
      element.classList.contains("acpmux-menu-item") && element.querySelector('[title="/work/site"]') !== null,
  );
  expect(site, "the folder list is missing").toBeTruthy();
  await act(async () => {
    site!.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1 }));
    site!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, button: 0, detail: 1 }));
  });
  await act(async () => resolveBrowse("/work/late"));
  expect(calls).toEqual([{ method: "newChat", cwd: "/work/site" }]);
});

test("New Chat Here also invalidates a pending folder browse", async () => {
  let resolveBrowse!: (cwd: string | undefined) => void;
  const calls = await mount({
    onBrowseFolder: () => new Promise<string | undefined>((resolve) => (resolveBrowse = resolve)),
  });
  await openFolder();
  const choose = everywhere().find(
    (element) => element.tagName === "BUTTON" && element.textContent?.trim() === "Choose folder…",
  );
  expect(choose, "no Choose folder action").toBeTruthy();
  await act(async () => choose!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true, detail: 1 })));
  expect(resolveBrowse).toBeTypeOf("function");

  await openFolder();
  const here = everywhere().find(
    (element) => element.tagName === "BUTTON" && element.textContent?.trim() === "New Chat Here",
  );
  expect(here, "no New Chat Here").toBeTruthy();
  await act(async () => here!.click());
  await act(async () => resolveBrowse("/work/late"));
  expect(calls).toEqual([{ method: "newChat", cwd: "/work/app" }]);
});
