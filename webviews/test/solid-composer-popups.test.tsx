// cmux#50983: a menu, picker or list opened from a composer is solid (an opaque surface, no blur, no
// host glass), so the composer's text, its chip rows, a suggestion list or a dialog under it never
// read through its rows; and only one stands at a time (a list that follows the field gives way to a
// chip's menu). ui/solidPopups.tsx, glass.css SOLID POPUPS.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Popover } from "../src/ui/Popover";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../src/ui/Menu";
import {
  anotherPopupOpen,
  popupSurfaceAttributes,
  SOLID_POPUP_ATTRIBUTE,
  SolidPopups,
  useYieldsToPopup,
  YIELDING_POPUP_ATTRIBUTE,
} from "../src/ui/solidPopups";
import { settleReact } from "./support/domTeardown";

const SRC = join(import.meta.dir, "../src");

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MutationObserver",
  "getComputedStyle",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  const ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    ResizeObserver,
    requestAnimationFrame: (callback: FrameRequestCallback) =>
      setTimeout(() => callback(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.assign(dom.window, { ResizeObserver });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const tick = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

test("a solid popup asks for no host glass; any other keeps its level", () => {
  expect(popupSurfaceAttributes(true, "menu")).toEqual({ [SOLID_POPUP_ATTRIBUTE]: "" });
  expect(popupSurfaceAttributes(true, "popover", false, true)).toEqual({
    [SOLID_POPUP_ATTRIBUTE]: "",
    [YIELDING_POPUP_ATTRIBUTE]: "",
  });
  expect(popupSurfaceAttributes(false, "menu")).toEqual({ "data-host-glass": "menu", "data-host-glass-cover": "" });
  expect(popupSurfaceAttributes(false, "popover", false)).toEqual({});
});

test("a popover opened inside a composer is solid, with no host glass", async () => {
  await act(async () => {
    root!.render(
      <SolidPopups>
        <Popover open onOpenChange={() => {}} anchor={container} label="Folders" initialFocus={false}>
          Folders
        </Popover>
      </SolidPopups>,
    );
  });
  const popover = document.querySelector(".ui-popover")!;
  expect(popover).toBeTruthy();
  expect(popover.hasAttribute(SOLID_POPUP_ATTRIBUTE)).toBe(true);
  expect(popover.hasAttribute("data-host-glass")).toBe(false);
  expect(popover.hasAttribute("data-host-glass-cover")).toBe(false);
});

test("a menu opened inside a composer is solid; one outside keeps the App's menu glass", async () => {
  const menu = (name: string) => (
    <Menu open onOpenChange={() => {}}>
      <MenuButton>{name}</MenuButton>
      <MenuPopup className={`menu-${name}`}>
        <MenuItem onClick={() => {}}>Full access</MenuItem>
      </MenuPopup>
    </Menu>
  );
  await act(async () => {
    root!.render(
      <>
        <SolidPopups>{menu("inside")}</SolidPopups>
        {menu("outside")}
      </>,
    );
  });
  await tick();
  const inside = document.querySelector(".menu-inside")!;
  const outside = document.querySelector(".menu-outside")!;
  expect(inside).toBeTruthy();
  expect(outside).toBeTruthy();
  expect(inside.hasAttribute(SOLID_POPUP_ATTRIBUTE)).toBe(true);
  expect(inside.hasAttribute("data-host-glass")).toBe(false);
  expect(outside.hasAttribute(SOLID_POPUP_ATTRIBUTE)).toBe(false);
  expect(outside.getAttribute("data-host-glass")).toBe("menu");
});

test("a yielding list counts no popup; a closing one counts none either", () => {
  const doc = dom!.window.document;
  const list = doc.createElement("div");
  list.setAttribute(SOLID_POPUP_ATTRIBUTE, "");
  list.setAttribute(YIELDING_POPUP_ATTRIBUTE, "");
  doc.body.append(list);
  expect(anotherPopupOpen(doc)).toBe(false);
  const menu = doc.createElement("div");
  menu.setAttribute(SOLID_POPUP_ATTRIBUTE, "");
  doc.body.append(menu);
  expect(anotherPopupOpen(doc)).toBe(true);
  menu.setAttribute("data-ending-style", "");
  expect(anotherPopupOpen(doc)).toBe(false);
});

test("a list that follows the field hides while a chip's menu is open, and comes back as it closes", async () => {
  function List() {
    const yielded = useYieldsToPopup(true, document);
    return yielded ? null : <div className="the-list" {...{ [SOLID_POPUP_ATTRIBUTE]: "", [YIELDING_POPUP_ATTRIBUTE]: "" }} />;
  }
  await act(async () => root!.render(<List />));
  expect(document.querySelector(".the-list")).toBeTruthy();
  const menu = document.createElement("div");
  menu.setAttribute(SOLID_POPUP_ATTRIBUTE, "");
  await act(async () => document.body.append(menu));
  await tick();
  expect(document.querySelector(".the-list")).toBeNull();
  await act(async () => menu.remove());
  await tick();
  expect(document.querySelector(".the-list")).toBeTruthy();
});

test("glass.css draws a solid popup on its opaque surface with no blur, past every glass rule", () => {
  const css = readFileSync(join(SRC, "ui/glass/glass.css"), "utf8");
  const start = css.indexOf(".ui-glass[data-popup-solid] {");
  expect(start).toBeGreaterThan(-1);
  const block = css.slice(start, css.indexOf("}", start));
  expect(block).toContain("--glass-tint: var(--glass-opaque) !important;");
  expect(block).toContain("background: var(--glass-opaque) !important;");
  expect(block).toContain("backdrop-filter: none !important;");
  expect(block).toContain("-webkit-backdrop-filter: none !important;");
  // After the host glass rules that clear a drawn surface's fill, so it is the last word.
  expect(start).toBeGreaterThan(css.lastIndexOf("background: var(--host-glass-fill, transparent);"));
});

test("both composers open their popups solid", () => {
  const composer = readFileSync(join(SRC, "agent-session/acpmux/Composer.tsx"), "utf8");
  expect(composer).toMatch(/<SolidPopups>\s*<MemoComposer/);
  const newTab = readFileSync(join(SRC, "agent-session/acpmux/newtab/NewTabScreen.tsx"), "utf8");
  expect(newTab).toContain("<SolidPopups>{page}</SolidPopups>");
  // The composer's own lists and pickers carry the marks too.
  for (const file of ["SlashMenu", "MentionMenu", "EmojiMenu", "PaletteMenu", "ModelPicker"]) {
    const source = readFileSync(join(SRC, `agent-session/acpmux/${file}.tsx`), "utf8");
    expect(source).toContain("useSolidPopupAttributes(");
  }
});
