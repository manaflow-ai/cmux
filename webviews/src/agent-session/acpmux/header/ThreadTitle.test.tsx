import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  ChatMenu,
  guardedChatMenu,
  menuGroups,
  menuItemForShortcut,
  menuKeycap,
  type ChatMenuItem,
} from "./ChatHeaderTools";
import { ThreadTitle } from "./ThreadTitle";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "KeyboardEvent",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  saved.set("requestAnimationFrame", scope.requestAnimationFrame);
  saved.set("cancelAnimationFrame", scope.cancelAnimationFrame);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const rows = (): ChatMenuItem[] => [
  { key: "rename", label: "Rename", icon: "action.edit", accelerator: "R", onSelect: () => undefined },
  { key: "delete", label: "Delete", icon: "tab.close", disabled: true, accelerator: "D" },
];

// Leo (2026-11-01), on the title's pill and its menu: "still background on the top right still the weird
// situation why is there a dropdown of this". The title is plain text; the chat's actions are in ⋮.
test("the chat title is plain text, not a menu button", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(<ThreadTitle title="Phone to computer connection" />);
  });
  const title = container.querySelector<HTMLElement>(".acpmux-thread-title")!;
  expect(title.tagName).toBe("SPAN");
  expect(title.textContent).toBe("Phone to computer connection");
  expect(title.title).toBe("Phone to computer connection");
  expect(container.querySelector("button, [role='button'], [aria-haspopup], [tabindex]")).toBeNull();
  expect(container.querySelector(".acpmux-thread-title-chevron")).toBeNull();
  await act(async () => title.click());
  expect(document.querySelector('[role="menu"]')).toBeNull();
});

test("a double-click on the title renames, a single click does not", async () => {
  const container = installDom();
  root = createRoot(container);
  let renamed = 0;
  await act(async () => {
    root!.render(<ThreadTitle title="A chat" onRename={() => renamed++} />);
  });
  const title = container.querySelector<HTMLElement>(".acpmux-thread-title")!;
  await act(async () => title.click());
  expect(renamed).toBe(0);
  await act(async () => {
    title.dispatchEvent(new dom!.window.MouseEvent("dblclick", { bubbles: true }));
  });
  expect(renamed).toBe(1);
});

test("the title draws no fill in any state (header.css)", () => {
  const css = readFileSync(join(import.meta.dir, "header.css"), "utf8");
  const rules = [...css.matchAll(/([^{}]*\.acpmux-thread-title[^{}]*)\{([^}]*)\}/g)];
  expect(rules.length).toBeGreaterThan(0);
  for (const [, selector, body] of rules) {
    const fill = /(?:^|;)\s*background(?:-color)?\s*:\s*([^;]+)/.exec(body!)?.[1]?.trim();
    if (fill !== undefined) expect(`${selector!.trim()}: ${fill}`).toMatch(/: (?:none|transparent)$/);
  }
  // No title trigger, chevron or hover/open state is styled any more.
  expect(css).not.toMatch(/thread-title-(?:trigger|chevron)/);
});

test("resolves explicit title-menu shortcut letters", () => {
  let selected = 0;
  const item = menuItemForShortcut(
    [{ key: "rename", label: "Rename", icon: "action.edit", accelerator: "R", onSelect: () => selected++ }],
    "r",
  );
  expect(item?.key).toBe("rename");
  item?.onSelect?.();
  expect(selected).toBe(1);
  expect(menuItemForShortcut(rows(), "D")?.disabled).toBe(true);
});

test("stored title and submenu actions become inert when their chat changes", () => {
  let session = "A";
  const ran: string[] = [];
  const guarded = guardedChatMenu(
    [
      { key: "archive", label: "Archive", icon: "inbox", onSelect: () => ran.push(session) },
      {
        key: "move",
        label: "Move",
        icon: "machine.remote",
        children: [{ key: "vm", label: "VM", onSelect: () => ran.push(session) }],
      },
    ],
    () => session === "A",
  );
  if (guarded[0] !== "separator") guarded[0]!.onSelect?.();
  session = "B";
  if (guarded[0] !== "separator") guarded[0]!.onSelect?.();
  if (guarded[1] !== "separator") guarded[1]!.children?.[0]?.onSelect();
  expect(ran).toEqual(["A"]);
});

test("a guarded title row passes its selection event on (Option-click Fork opens the chooser)", () => {
  const seen: unknown[] = [];
  const [row] = guardedChatMenu(
    [{ key: "fork", label: "Fork", icon: "agent.fork", onSelect: (event) => seen.push(event?.altKey) }],
    () => true,
  );
  if (row !== "separator") row!.onSelect?.({ altKey: true } as never);
  expect(seen).toEqual([true]);
});

// Leo (2026-10-31): "I ALREADY TOLD YOU GUYS THIS IS FUCKING WEIRD TO SEE ON THE FUCKING RIGHT IDK WHAT
// IM SUPPOSED TO DO WITH THESE". A menu row draws a keycap only when it carries a modifier.
const MODIFIER = /[⌘⌥⌃⇧]/;

test("a chat menu draws no bare letter keycaps, and a typed letter still picks its row", async () => {
  const container = installDom();
  root = createRoot(container);
  let renamed = 0;
  await act(async () =>
    root!.render(
      <ChatMenu
        registerPickerLabel={null}
        items={() =>
          menuGroups(
            [
              { key: "rename", label: "Rename", icon: "action.edit", accelerator: "R", onSelect: () => renamed++ },
              { key: "fork", label: "Fork", icon: "agent.fork", accelerator: "F", onSelect: () => undefined },
              {
                key: "open",
                label: "Open in",
                icon: "app.open.external",
                accelerator: "O",
                children: [{ key: "browser", label: "Browser", accelerator: "B", onSelect: () => undefined }],
              },
            ],
            [
              { key: "archive", label: "Archive", icon: "inbox", accelerator: "A", onSelect: () => undefined },
              { key: "delete", label: "Delete", icon: "action.delete", accelerator: "D", onSelect: () => undefined },
            ],
          )
        }
      />,
    ),
  );
  await act(async () => container.querySelector<HTMLButtonElement>("button")!.click());
  const menu = document.querySelector('[role="menu"]')!;
  for (const key of menu.querySelectorAll("kbd")) expect(key.textContent ?? "").toMatch(MODIFIER);
  // One divider, before the destructive pair.
  expect(menu.querySelectorAll('[role="separator"]').length).toBe(1);
  await act(async () =>
    menu.dispatchEvent(new KeyboardEvent("keydown", { key: "r", bubbles: true, cancelable: true })),
  );
  expect(renamed).toBe(1);
});

test("menuKeycap keeps modifier shortcuts and drops bare letters", () => {
  expect(menuKeycap("⌘N")).toBe("⌘N");
  expect(menuKeycap("⇧⌘I")).toBe("⇧⌘I");
  for (const bare of ["R", "F", "A", "D", "7", "", undefined]) expect(menuKeycap(bare)).toBeUndefined();
});

// Lint: a dropdown/context menu row in the web UI never puts a bare-letter literal in a <kbd>. Menus
// render keycaps through menuKeycap(); a literal like <kbd>R</kbd> next to a MenuItem fails here.
test("no menu file renders a bare single-character keycap literal", () => {
  const root = join(import.meta.dir, "../../..");
  const files: string[] = [];
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (path.endsWith(".tsx") && !path.endsWith(".test.tsx")) files.push(path);
    }
  };
  walk(root);
  const offenders: string[] = [];
  for (const file of files) {
    const source = readFileSync(file, "utf8");
    if (!/\b(MenuItem|MenuPopup|ContextMenu|Submenu)\b/.test(source)) continue;
    for (const match of source.matchAll(/<kbd[^>]*>\s*([A-Za-z0-9])\s*<\/kbd>/g)) {
      // A split chord (<kbd>⌘</kbd><kbd>K</kbd>) carries its modifier in the keycap just before.
      const before = source.slice(Math.max(0, match.index - 120), match.index);
      if (/<kbd[^>]*>\s*[⌘⌥⌃⇧]+\s*<\/kbd>\s*$/.test(before)) continue;
      offenders.push(`${file.slice(root.length + 1)}: <kbd>${match[1]}</kbd>`);
    }
    for (const match of source.matchAll(/\b(?:shortcutLabel|keycap|shortcut|hint):\s*"([A-Za-z0-9])"/g))
      offenders.push(`${file.slice(root.length + 1)}: ${match[0]}`);
  }
  expect(offenders).toEqual([]);
});
