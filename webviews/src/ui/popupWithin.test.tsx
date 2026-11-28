// A transcript row keeps its actions shown while a popup opened from inside it is open, through
// `data-popup-within` on the opener's ancestors up to the row (ui/popupWithin.ts), never through a
// `:has([data-popup-open])` rule: Chromium walked the whole row for that `:has()` on every element the
// rule could style, each time a page of an older chat mounted (about 250 ms of style recalc for 24
// older pages, transcript-scroll-up.bench.ts TRACE=3). Every open path marks the row and every close
// path, unmount included, clears it.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextMenu } from "./ContextMenu";
import { Menu, MenuButton, MenuItem, MenuPopup } from "./Menu";
import { installNativeMenu } from "./nativeMenu";
import { markPopupWithin, POPUP_WITHIN } from "./popupWithin";

/// The transcript's row stylesheets (agent-session/acpmux), whose rules ask whether a popup is open in a row.
const ROW_SHEETS = [
  "conversation/conversation.css",
  "conversation/CardCopy.css",
  "conversation/AgentMessageRow.css",
  "conversation/MessageGroupHead.css",
  "conversation/EditedFilesCard.css",
  "turnChanges/turnChanges.css",
  "subagents/SubagentDoneLine.css",
];

test("no transcript row rule asks `:has([data-popup-open])`", () => {
  const acpmux = join(import.meta.dir, "../agent-session/acpmux");
  const found = ROW_SHEETS.flatMap((sheet) =>
    readFileSync(join(acpmux, sheet), "utf8")
      .split("\n")
      .flatMap((line, index) => (line.includes(":has([data-popup-open])") ? [`${sheet}:${index + 1}`] : [])),
  );
  console.log(`row :has([data-popup-open]) rules: ${found.length}`);
  expect(found).toEqual([]);
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM(
    '<!doctype html><html><body><div class="acpmux-thread"><article class="acpmux-row"><div class="cv-user"><div id="root"></div></div></article></div></body></html>',
    { url: "http://localhost/" },
  );
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "MouseEvent",
    "PointerEvent",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "MutationObserver",
    "KeyboardEvent",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MouseEvent: dom.window.MouseEvent,
    PointerEvent: dom.window.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    MutationObserver: dom.window.MutationObserver,
    KeyboardEvent: dom.window.KeyboardEvent,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  installNativeMenu(null);
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const marked = () =>
  [...document.querySelectorAll(`[${POPUP_WITHIN}]`)].map(
    (element) => element.className || element.id || element.tagName,
  );

test("an opener marks its ancestors up to its row, and two openers clear only when both close", () => {
  const container = installDom();
  container.innerHTML = '<span class="a"><button id="one"></button></span><button id="two"></button>';
  const one = markPopupWithin(document.getElementById("one"));
  const two = markPopupWithin(document.getElementById("two"));
  // Not the thread above the row: the marks stop at the row.
  expect(marked()).toEqual(["acpmux-row", "cv-user", "root", "a"]);
  one();
  one();
  expect(marked()).toEqual(["acpmux-row", "cv-user", "root"]);
  two();
  expect(marked()).toEqual([]);
});

test("a context menu in a row marks the row while open, and clears on dismiss and on unmount", async () => {
  let dismiss: ((reply: unknown) => void) | undefined;
  installNativeMenu(
    () =>
      new Promise((resolve) => {
        dismiss = resolve;
      }),
  );
  const container = installDom();
  const show = () =>
    act(() =>
      root!.render(
        <ContextMenu items={[{ id: "copy", label: "Copy", onSelect: () => {} }]}>
          <button type="button" id="target">
            Row
          </button>
        </ContextMenu>,
      ),
    );
  root = createRoot(container);
  show();
  const rightClick = async () =>
    act(async () => {
      document
        .getElementById("target")!
        .dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 4, clientY: 6 }));
      await Promise.resolve();
    });
  expect(marked()).toEqual([]);
  await rightClick();
  expect(marked()).toContain("acpmux-row");
  expect(marked()).toContain("cv-user");
  dismiss?.({ picked: null });
  await act(async () => {
    await Promise.resolve();
  });
  expect(marked()).toEqual([]);
  await rightClick();
  expect(marked()).toContain("acpmux-row");
  act(() => root!.render(<span />));
  expect(marked()).toEqual([]);
});

test("a menu button in a row marks the row while its menu is open, and clears on close and on unmount", () => {
  const container = installDom();
  root = createRoot(container);
  const show = (open: boolean) =>
    act(() =>
      root!.render(
        <Menu open={open}>
          <MenuButton label="More">…</MenuButton>
          <MenuPopup>
            <MenuItem onSelect={() => {}}>Copy</MenuItem>
          </MenuPopup>
        </Menu>,
      ),
    );
  show(false);
  expect(marked()).toEqual([]);
  show(true);
  expect(marked()).toEqual(["acpmux-row", "cv-user", "root"]);
  show(false);
  expect(marked()).toEqual([]);
  show(true);
  expect(marked()).toEqual(["acpmux-row", "cv-user", "root"]);
  act(() => root!.render(<span />));
  expect(marked()).toEqual([]);
});
