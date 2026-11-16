// Every right-click menu in the app is a standard macOS menu (Lawrence 2026-10-23: "we don't want
// ANYTHING custom besides the icons"): with the host's native menu installed, a right-click hands
// it the rows and the pointer and draws nothing in the page; the chosen row runs. Without a host,
// or when the host refuses (an older app), the page draws its own menu.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";
import { installNativeMenu, type NativeMenuRequest } from "./nativeMenu";
import { contextDescription } from "./popupDescriptors";
import type { PopupHost } from "./popupHost";
import { UiProvider } from "./UiProvider";

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
    "MouseEvent",
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

function render(items: ContextMenuItem[]): HTMLElement {
  const container = installDom();
  root = createRoot(container);
  act(() =>
    root!.render(
      <ContextMenu items={items}>
        <button type="button" id="target">
          Row
        </button>
      </ContextMenu>,
    ),
  );
  return container.querySelector("#target")!;
}

async function rightClick(target: HTMLElement): Promise<void> {
  await act(async () => {
    target.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 40, clientY: 60 }));
    await Promise.resolve();
  });
}

function items(ran: string[]): ContextMenuItem[] {
  return [
    { id: "rename", label: "Rename", symbol: "pencil", onSelect: () => ran.push("rename") },
    { id: "copy", label: <b>Copy</b>, ariaLabel: "Copy", disabled: true, onSelect: () => ran.push("copy") },
    { id: "close", label: "Close", separatorBefore: true, destructive: true, onSelect: () => ran.push("close") },
  ];
}

test("a right-click opens the app's native menu with the rows, and its pick runs", async () => {
  const ran: string[] = [];
  const asked: NativeMenuRequest[] = [];
  installNativeMenu(async (request) => {
    asked.push(request);
    return { picked: "close" };
  });
  const target = render(items(ran));
  await rightClick(target);
  expect(asked).toEqual([
    {
      items: [
        { id: "rename", label: "Rename", symbol: "pencil" },
        { id: "copy", label: "Copy", disabled: true },
        { id: "separator:close", label: "", separator: true },
        { id: "close", label: "Close" },
      ],
      point: { x: 40, y: 60 },
    },
  ]);
  expect(document.querySelector(".ui-context-menu")).toBeNull();
  expect(target.hasAttribute("data-popup-open")).toBe(false);
  expect(ran).toEqual(["close"]);
});

test("a native context menu marks its opener until dismissal", async () => {
  let resolveNative: ((reply: unknown) => void) | undefined;
  installNativeMenu(
    () =>
      new Promise((resolve) => {
        resolveNative = resolve;
      }),
  );
  const target = render(items([]));
  await rightClick(target);
  expect(target.getAttribute("data-popup-open")).toBe("");
  resolveNative?.({ picked: null });
  await act(async () => {
    await Promise.resolve();
  });
  expect(target.hasAttribute("data-popup-open")).toBe(false);
});

test("a dismissed native menu runs nothing and draws nothing", async () => {
  const ran: string[] = [];
  installNativeMenu(async () => ({ picked: null }));
  await rightClick(render(items(ran)));
  expect(document.querySelector(".ui-context-menu")).toBeNull();
  expect(ran).toEqual([]);
});

test("a host that refuses the native menu leaves the page's own", async () => {
  installNativeMenu(() => Promise.reject(new Error("unknown op")));
  const target = render(items([]));
  await rightClick(target);
  expect(target.getAttribute("data-popup-open")).toBe("");
  expect(document.querySelector(".ui-context-menu")).not.toBeNull();
});

test("a keyboard context-menu request marks the focused opener", async () => {
  const target = render(items([]));
  await act(async () => {
    target.dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "ContextMenu", bubbles: true, cancelable: true }),
    );
    await Promise.resolve();
  });
  expect(target.getAttribute("data-popup-open")).toBe("");
  expect(document.querySelector(".ui-context-menu")).not.toBeNull();
});

test("a newer context-menu request supersedes an older native reply", async () => {
  const resolveNative: Array<(reply: unknown) => void> = [];
  installNativeMenu(
    () =>
      new Promise((resolve) => {
        resolveNative.push(resolve);
      }),
  );
  const target = render(items([]));
  await rightClick(target);
  await rightClick(target);
  resolveNative[0]?.(null);
  await Promise.resolve();
  expect(document.querySelector(".ui-context-menu")).toBeNull();
  resolveNative[1]?.({ picked: null });
  await Promise.resolve();
  expect(target.hasAttribute("data-popup-open")).toBe(false);
});

test("unmount clears an opener marker and ignores a stale native reply", async () => {
  let resolveNative: ((reply: unknown) => void) | undefined;
  installNativeMenu(
    () =>
      new Promise((resolve) => {
        resolveNative = resolve;
      }),
  );
  const target = render(items([]));
  await rightClick(target);
  expect(target.getAttribute("data-popup-open")).toBe("");
  act(() => root?.unmount());
  expect(target.hasAttribute("data-popup-open")).toBe(false);
  resolveNative?.({ picked: null });
  await Promise.resolve();
});

test("an older host that answers without a native pick leaves the page's own", async () => {
  // Legacy bridge shims answer unknown methods with `{ok: true, value: null}`. Treat the
  // missing `{picked}` envelope as an unsupported host, rather than swallowing the menu.
  installNativeMenu(() => Promise.resolve(null));
  await rightClick(render(items([])));
  expect(document.querySelector(".ui-context-menu")).not.toBeNull();
});

test("without a host the page draws its menu", async () => {
  const target = render(items([]));
  await rightClick(target);
  expect(target.getAttribute("data-popup-open")).toBe("");
  expect(document.querySelector(".ui-context-menu")).not.toBeNull();
  await act(async () => {
    document
      .querySelector<HTMLElement>(".ui-context-menu-backdrop")
      ?.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
  });
  expect(target.hasAttribute("data-popup-open")).toBe(false);
});

test("toggle state reaches the native menu and the page's accessible checkbox", async () => {
  const asked: NativeMenuRequest[] = [];
  installNativeMenu(async (request) => {
    asked.push(request);
    return { picked: null };
  });
  const target = render([{ id: "follow", label: "Follow", checked: false, onSelect() {} }]);
  await rightClick(target);
  expect(asked[0]?.items).toEqual([{ id: "follow", label: "Follow", checked: false }]);
  installNativeMenu(null);
  await rightClick(target);
  expect(document.querySelector('[role="menuitemcheckbox"]')?.getAttribute("aria-checked")).toBe("false");
});

/** A popup host whose declarative native popup answers `shown` (false: it never drew the rows). */
function nativeHost(shown: boolean, models: unknown[]): PopupHost {
  return {
    native: {
      show: async (model) => {
        models.push(model);
        return { shown };
      },
      update() {},
      hide() {},
      listen: () => () => {},
    },
    show: async () => ({}),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
  };
}

function renderNative(host: PopupHost): HTMLElement {
  const container = installDom();
  root = createRoot(container);
  const rows = [{ id: "send", label: "Send", shortcut: "↩" }];
  act(() =>
    root!.render(
      <UiProvider container={container} popupHost={host}>
        <ContextMenu
          items={[{ id: "send", label: "Send", onSelect: () => {} }]}
          native={{ model: contextDescription(rows) }}
        >
          <button type="button" id="target">
            Row
          </button>
        </ContextMenu>
      </UiProvider>,
    ),
  );
  return container.querySelector("#target")!;
}

test("a declarative native menu the host draws leaves nothing in the page", async () => {
  const models: unknown[] = [];
  await rightClick(renderNative(nativeHost(true, models)));
  await act(async () => await Promise.resolve());
  expect(models.length).toBe(1);
  expect(document.querySelector(".ui-context-menu")).toBeNull();
});

test("a declarative native menu the host refuses opens the page's own at the right-click", async () => {
  const models: unknown[] = [];
  const target = renderNative(nativeHost(false, models));
  await rightClick(target);
  await act(async () => await Promise.resolve());
  expect(models.length).toBe(1);
  const menu = document.querySelector<HTMLElement>(".ui-context-menu");
  expect(menu).not.toBeNull();
  expect(menu!.style.left).toBe("40px");
  expect(target.getAttribute("data-popup-open")).toBe("");
});

test("asChild puts the menu on the child itself: no wrapper, its siblings stay its own", async () => {
  const ran: string[] = [];
  const container = installDom();
  root = createRoot(container);
  act(() =>
    root!.render(
      <div id="row">
        <ContextMenu asChild items={items(ran)}>
          <button type="button" id="target">
            Send
          </button>
        </ContextMenu>
        <span id="mic" />
      </div>,
    ),
  );
  const target = container.querySelector<HTMLElement>("#target")!;
  expect(target.parentElement?.id).toBe("row");
  expect(container.querySelector("#row > #target + #mic")).not.toBeNull();
  expect(container.querySelector(".ui-context-menu-host")).toBeNull();
  await rightClick(target);
  expect(document.querySelector(".ui-context-menu")).not.toBeNull();
  act(() => document.querySelector<HTMLElement>('[role="menuitem"]')!.click());
  expect(ran).toEqual(["rename"]);
});

test("a right-click on the page's own menu stays in the menu, also under asChild", async () => {
  const container = installDom();
  root = createRoot(container);
  act(() =>
    root!.render(
      <div id="row">
        <ContextMenu asChild items={items([])}>
          <button type="button" id="target">
            Send
          </button>
        </ContextMenu>
      </div>,
    ),
  );
  const target = container.querySelector<HTMLElement>("#target")!;
  /// A real secondary click: pointerdown (button 2), then contextmenu, on the same element.
  const secondary = (at: Element) => {
    const press = new MouseEvent("pointerdown", { bubbles: true, cancelable: true, button: 2 });
    const menu = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, button: 2 });
    act(() => void at.dispatchEvent(press));
    act(() => void at.dispatchEvent(menu));
    return menu;
  };
  await rightClick(target);
  // On a row: the menu stays open and the browser's own menu never opens over it.
  expect(secondary(document.querySelector('[role="menuitem"]')!).defaultPrevented).toBe(true);
  expect(document.querySelector(".ui-context-menu")).not.toBeNull();
  // On the backdrop: the menu closes, as a click there does, and the browser's menu stays shut.
  expect(secondary(document.querySelector(".ui-context-menu-backdrop")!).defaultPrevented).toBe(true);
  expect(document.querySelector(".ui-context-menu")).toBeNull();
  expect(target.hasAttribute("data-popup-open")).toBe(false);
  // A middle click sends no contextmenu after its pointerdown: the backdrop closes on the press.
  await rightClick(target);
  act(
    () =>
      void document
        .querySelector(".ui-context-menu-backdrop")!
        .dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, cancelable: true, button: 1 })),
  );
  expect(document.querySelector(".ui-context-menu")).toBeNull();
});
