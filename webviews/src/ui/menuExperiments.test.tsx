// The menu experiments (menu-style-v2, menu-row-states; lane taste-menus-v2). Arm off draws today's
// menus; v2 moves destructive rows into one last group and gives every row of a group with an icon
// the icon slot; row states draw a disabled row's reason and keep an async row's menu open, at its
// size, until the row's work settles.
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextMenu, type ContextMenuItem } from "./ContextMenu";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuRadioGroup, MenuRadioItem } from "./Menu";
import { arrangeMenuRows } from "./menuArrange";
import { settleReact } from "../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "MutationObserver",
  "IS_REACT_ACT_ENVIRONMENT",
  "cmuxExperiments",
];

function render(node: React.ReactNode, arms: Record<string, string> = {}): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    MutationObserver: win.MutationObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
    cmuxExperiments: arms,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
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

const tick = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

async function rightClick(doc: Document): Promise<void> {
  await act(async () => {
    doc.querySelector("#target")!.dispatchEvent(
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 40,
        clientY: 60,
      }),
    );
    await Promise.resolve();
  });
}

const workspaceRows = (ran: string[] = []): ContextMenuItem[] => [
  { id: "rename", label: "Rename", icon: <i />, onSelect: () => ran.push("rename") },
  { id: "close", label: "Close Workspace", destructive: true, onSelect: () => ran.push("close") },
  { id: "pin", label: "Pin", onSelect: () => ran.push("pin") },
  {
    id: "new",
    label: "New Workspace Below",
    separatorBefore: true,
    onSelect: () => ran.push("new"),
  },
  { id: "copy", label: "Copy Path", onSelect: () => ran.push("copy") },
];

function contextMenu(items: ContextMenuItem[]) {
  return (
    <ContextMenu items={items}>
      <button type="button" id="target">
        Row
      </button>
    </ContextMenu>
  );
}

const labels = (doc: Document, scopeSelector = ".ui-context-menu") =>
  [...doc.querySelectorAll(`${scopeSelector} > .ui-popup-scroll > [role="none"]`)].map((row) => ({
    label: row.querySelector(".ui-menu-label")?.textContent,
    separator: Boolean(row.querySelector(":scope > hr")),
    slot: Boolean(row.querySelector(".ui-menu-icon")),
  }));

describe("arrangeMenuRows", () => {
  test("destructive rows move, in order, into one last group; an emptied group drops out", () => {
    const rows = arrangeMenuRows([
      { id: "a" },
      { id: "x", destructive: true },
      { id: "b", separatorBefore: true },
      { id: "y", destructive: true, separatorBefore: true },
      { id: "c", separatorBefore: true },
    ]);
    expect(rows.map((row) => [row.item.id, row.separatorBefore])).toEqual([
      ["a", false],
      ["b", true],
      ["c", true],
      ["x", true],
      ["y", false],
    ]);
  });

  test("icons are all-or-none per divider group", () => {
    const rows = arrangeMenuRows([
      { id: "a", icon: "i" },
      { id: "b" },
      { id: "c", separatorBefore: true },
      { id: "d" },
    ]);
    expect(rows.map((row) => row.iconSlot)).toEqual([false, false, false, false]);
    const full = arrangeMenuRows([
      { id: "a", icon: "i" },
      { id: "b", icon: "i" },
      { id: "c", separatorBefore: true },
    ]);
    expect(full.map((row) => row.iconSlot)).toEqual([true, true, false]);
  });
});

describe("ContextMenu", () => {
  test("arm off draws the rows as given, with no experiment attributes", async () => {
    const doc = render(contextMenu(workspaceRows()));
    await rightClick(doc);
    const menu = doc.querySelector(".ui-context-menu")!;
    expect(menu.hasAttribute("data-menu-style")).toBe(false);
    expect(menu.hasAttribute("data-menu-states")).toBe(false);
    expect(labels(doc)).toEqual([
      { label: "Rename", separator: false, slot: true },
      { label: "Close Workspace", separator: false, slot: false },
      { label: "Pin", separator: false, slot: false },
      { label: "New Workspace Below", separator: true, slot: false },
      { label: "Copy Path", separator: false, slot: false },
    ]);
    expect(doc.querySelector(".ui-context-submenu-host, .ui-menu-async, .ui-menu-reason")).toBeNull();
  });

  test("v2 sorts the destructive row last, in red, and drops the icons of a mixed group", async () => {
    const doc = render(contextMenu(workspaceRows()), { "menu-style-v2": "v2" });
    await rightClick(doc);
    expect(doc.querySelector(".ui-context-menu")!.getAttribute("data-menu-style")).toBe("v2");
    expect(labels(doc)).toEqual([
      { label: "Rename", separator: false, slot: false },
      { label: "Pin", separator: false, slot: false },
      { label: "New Workspace Below", separator: true, slot: false },
      { label: "Copy Path", separator: false, slot: false },
      { label: "Close Workspace", separator: true, slot: false },
    ]);
    const last = [...doc.querySelectorAll(".ui-context-menu .ui-menu-item")].at(-1)!;
    expect(last.classList.contains("ui-menu-item-destructive")).toBe(true);
  });

  test("a submenu row opens its submenu on ArrowRight; Enter runs its row", async () => {
    const ran: string[] = [];
    const doc = render(
      contextMenu([
        {
          id: "split",
          label: "Split",
          onSelect: () => ran.push("split"),
          submenu: [
            { id: "right", label: "Split Right", onSelect: () => ran.push("right") },
            { id: "down", label: "Split Down", onSelect: () => ran.push("down") },
          ],
        },
      ]),
    );
    await rightClick(doc);
    const menu = doc.querySelector<HTMLElement>(".ui-context-menu")!;
    await act(async () => {
      menu.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
    });
    expect(doc.querySelectorAll('[role="menu"]').length).toBe(2);
    await act(async () => {
      menu.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    });
    await act(async () => {
      menu.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    expect(ran).toEqual(["down"]);
    expect(doc.querySelector('[role="menu"]')).toBeNull();
  });

  test("row states: a disabled row draws its reason under its label", async () => {
    const rows: ContextMenuItem[] = [
      {
        id: "cloud",
        label: "Open in Cloud",
        disabled: true,
        reason: "Needs sign-in",
        onSelect: () => {},
      },
    ];
    const off = render(contextMenu(rows));
    await rightClick(off);
    expect(off.querySelector(".ui-menu-reason")).toBeNull();
    await act(async () => root!.unmount());
    root = undefined;
    const doc = render(contextMenu(rows), { "menu-row-states": "on" });
    await rightClick(doc);
    const reason = doc.querySelector(".ui-menu-item .ui-menu-text .ui-menu-reason")!;
    expect(reason.textContent).toBe("Needs sign-in");
    expect(doc.querySelector(".ui-menu-item")!.getAttribute("aria-describedby")).toBe(reason.id);
  });

  test("row states: an async row spins at the menu's size and closes it when its work settles", async () => {
    let finish!: () => void;
    const doc = render(
      contextMenu([
        {
          id: "pr",
          label: "Open PR",
          async: true,
          onSelect: () => new Promise<void>((done) => (finish = done)),
        },
        { id: "copy", label: "Copy Path", onSelect: () => {} },
      ]),
      { "menu-row-states": "on" },
    );
    await rightClick(doc);
    const row = () => doc.querySelector<HTMLElement>('.ui-menu-item[aria-label="Open PR"]');
    // The slot is drawn before the work starts, so the spinner adds no box to the row.
    const before = row()!.querySelectorAll(":scope > *").length;
    expect(row()!.querySelector(".ui-menu-async")).not.toBeNull();
    await act(async () => row()!.click());
    expect(doc.querySelector(".ui-context-menu")).not.toBeNull();
    expect(row()!.hasAttribute("data-pending")).toBe(true);
    expect(row()!.querySelectorAll(":scope > *").length).toBe(before);
    expect(row()!.querySelector(".ui-menu-async > .ui-menu-spinner")).not.toBeNull();
    // A second pick while it runs does nothing.
    await act(async () => doc.querySelector<HTMLElement>('.ui-menu-item[aria-label="Copy Path"]')!.click());
    expect(doc.querySelector(".ui-context-menu")).not.toBeNull();
    await act(async () => {
      finish();
      await Promise.resolve();
    });
    await tick();
    expect(doc.querySelector(".ui-context-menu")).toBeNull();
  });
});

describe("Menu", () => {
  function picker(onOpenPr?: () => Promise<void>) {
    return (
      <Menu open>
        <MenuButton label="Model">Model</MenuButton>
        <MenuPopup label="Model">
          <MenuRadioGroup value="opus" onValueChange={() => {}}>
            <MenuRadioItem value="opus">Opus</MenuRadioItem>
            <MenuRadioItem value="cloud" disabled reason="Needs sign-in">
              Cloud model
            </MenuRadioItem>
          </MenuRadioGroup>
          {onOpenPr ? (
            <MenuItem async onSelect={onOpenPr}>
              Open PR
            </MenuItem>
          ) : null}
        </MenuPopup>
      </Menu>
    );
  }

  test("arm off: no experiment attributes, no reason, no async slot", async () => {
    const doc = render(picker(() => Promise.resolve()));
    await tick();
    const popup = doc.querySelector(".ui-menu")!;
    expect(popup).not.toBeNull();
    expect(popup.hasAttribute("data-menu-style")).toBe(false);
    expect(popup.hasAttribute("data-menu-states")).toBe(false);
    expect(doc.querySelector("[data-menu-join]")).toBeNull();
    expect(doc.querySelector(".ui-menu-reason, .ui-menu-text, .ui-menu-async")).toBeNull();
  });

  test("row states: the disabled model's reason, the trigger joined to its open menu", async () => {
    const doc = render(picker(), { "menu-row-states": "on", "menu-style-v2": "v2" });
    await tick();
    const popup = doc.querySelector(".ui-menu")!;
    expect(popup.getAttribute("data-menu-states")).toBe("on");
    expect(popup.getAttribute("data-menu-style")).toBe("v2");
    expect(doc.querySelector(".ui-menu-reason")!.textContent).toBe("Needs sign-in");
    expect(doc.querySelector("button[data-menu-join][data-popup-open]")).not.toBeNull();
  });

  test("row states: an async row keeps the menu open while it runs, then closes it", async () => {
    let finish!: () => void;
    let open = true;
    const doc = render(
      <Menu
        open={open}
        onOpenChange={(next) => {
          open = next;
        }}
      >
        <MenuButton label="Actions">Actions</MenuButton>
        <MenuPopup label="Actions">
          <MenuItem async onSelect={() => new Promise<void>((done) => (finish = done))}>
            Open PR
          </MenuItem>
        </MenuPopup>
      </Menu>,
      { "menu-row-states": "on" },
    );
    await tick();
    const row = () => doc.querySelector<HTMLElement>('[role="menuitem"]')!;
    await act(async () => row().click());
    await tick();
    expect(open).toBe(true);
    expect(row().hasAttribute("data-pending")).toBe(true);
    expect(row().querySelector(".ui-menu-async > .ui-menu-spinner")).not.toBeNull();
    await act(async () => {
      finish();
      await Promise.resolve();
    });
    await tick();
    expect(open).toBe(false);
  });
});
