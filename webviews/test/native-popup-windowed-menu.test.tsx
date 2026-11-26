// Review follow-up on #46214 (F1): a windowed menu (menuWindow.tsx) mounts only the rows near its
// viewport, so in a pane too short for it the native popup would get those rows alone and the
// page's scroller would be hidden: the rest of the actions and modes could not be reached. Such a
// menu stays in the page's popup, which scrolls; a plain menu of the same height still escapes.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { useEscapingPopup, type PopupHost } from "../src/ui/popupHost";
import { ROW_ATTRIBUTE } from "../src/ui/menuWindow";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test.each([
  ["a windowed menu stays in the page", true],
  ["a plain menu escapes", false],
] as const)("in a short pane, %s", async (_name, windowed) => {
  const row = (index: number) =>
    `<div ${windowed ? `${ROW_ATTRIBUTE}="${index}"` : ""}><button role="menuitem">Row ${index}</button></div>`;
  dom = new JSDOM(
    `<!doctype html><main id="root"></main><div id="shell" style="position:fixed;z-index:9"><div id="menu" role="menu">${[0, 1, 2].map(row).join("")}</div></div>`,
    { pretendToBeVisual: true },
  );
  const document = dom.window.document;
  const frames = new Map<number, FrameRequestCallback>();
  let serial = 0;
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    innerHeight: 100,
    innerWidth: 500,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (callback: FrameRequestCallback) => {
      frames.set(++serial, callback);
      return serial;
    },
    cancelAnimationFrame: (id: number) => frames.delete(id),
  };
  for (const key of Object.keys(replacements)) saved.set(key, scope[key]);
  Object.assign(scope, replacements);
  Object.defineProperty(dom.window, "innerHeight", { configurable: true, value: 100 });
  Object.defineProperty(dom.window, "innerWidth", { configurable: true, value: 500 });
  const menu = document.getElementById("menu")!;
  const shell = document.getElementById("shell")!;
  Object.defineProperty(menu, "offsetHeight", { value: 120 });
  let shown = 0;
  let owner: object | null = null;
  const host: PopupHost = {
    show(_model, next) {
      shown++;
      owner = next;
      return Promise.resolve({ shown: true });
    },
    update() {},
    hide() {
      owner = null;
    },
    owner: () => owner,
    listen: () => () => {},
  };
  const anchor = () => ({ getBoundingClientRect: () => ({ left: 0, right: 100, top: 40, bottom: 60 }) });
  function Consumer() {
    useEscapingPopup(host, menu, anchor, { side: "bottom", align: "start", gap: 4 });
    return null;
  }
  root = createRoot(document.getElementById("root")!);
  await act(async () => root!.render(<Consumer />));
  await act(async () => {
    const pending = [...frames.values()];
    frames.clear();
    for (const callback of pending) callback(0);
  });
  expect(shown).toBe(windowed ? 0 : 1);
  expect(shell.hasAttribute("data-escaped")).toBe(!windowed);
  expect(shell.style.getPropertyValue("pointer-events")).toBe(windowed ? "" : "none");
});
