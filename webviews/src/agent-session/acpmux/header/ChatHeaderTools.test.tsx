import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Node",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The menu is the shared Base UI menu (src/ui), which reaches for DOM classes by name.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) =>
    /^(HTML|SVG|Element|Event|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Shadow|Document|Mutation|Resize|getComputedStyle)/.test(
      key,
    ) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ChatHeaderTools, HEADER_ACTIONS } = await import("./ChatHeaderTools");
type ChatMenuItem = import("./ChatHeaderTools").ChatMenuItem;
const { ShortcutsContext } = await import("../shortcuts");

async function render(props: Partial<Parameters<typeof ChatHeaderTools>[0]>, ran: string[]) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const menu = (): ChatMenuItem[] => [
    {
      key: "rename",
      label: "Rename",
      icon: "action.edit",
      shortcutAction: HEADER_ACTIONS.rename,
      onSelect: () => ran.push("rename"),
    },
    "separator",
    {
      key: "continue",
      label: "Continue in",
      icon: "agent.handoff",
      children: [{ key: "codex", label: "Codex", onSelect: () => ran.push("continue:codex") }],
    },
    { key: "close", label: "Close", icon: "tab.close", disabled: true, onSelect: () => ran.push("close") },
  ];
  await act(async () =>
    root.render(
      createElement(
        ShortcutsContext.Provider,
        { value: { splitRight: "⌘D", splitBrowserRight: "⌥⌘D", renameTab: "⌘R" } },
        createElement(ChatHeaderTools, {
          changesOpen: false,
          onChanges: () => ran.push("changes"),
          onTerminal: () => ran.push("terminal"),
          onBrowser: () => ran.push("browser"),
          summary: null,
          menu,
          ...props,
        }),
      ),
    ),
  );
  return { container, unmount: () => act(async () => root.unmount()) };
}

test("every header tool is there from the first frame; Changes waits for an edit without moving", async () => {
  const ran: string[] = [];
  const { container, unmount } = await render({}, ran);
  const buttons = [
    ...container.querySelectorAll<HTMLButtonElement>(".acpmux-header-tools > button, .acpmux-chat-menu > button"),
  ];
  expect(buttons.map((button) => button.getAttribute("aria-label"))).toEqual([
    "Changes",
    "Terminal",
    "Browser",
    "Chat actions",
  ]);
  const changes = buttons[0]!;
  expect(changes.disabled).toBe(true);
  expect(changes.textContent).not.toContain("+0");
  expect(changes.textContent).not.toContain("-0");
  expect(buttons[1]!.title).toBe("Terminal (⌘D)");
  expect(buttons[2]!.title).toBe("Browser (⌥⌘D)");
  await act(async () => buttons[1]!.click());
  await act(async () => buttons[2]!.click());
  expect(ran).toEqual(["terminal", "browser"]);
  await unmount();
});

test("Changes shows the last turn's counts and toggles the changes view", async () => {
  const ran: string[] = [];
  const { container, unmount } = await render({ changes: { additions: 85, deletions: 14 }, changesOpen: true }, ran);
  const changes = container.querySelector<HTMLButtonElement>(".acpmux-header-changes")!;
  expect(changes.disabled).toBe(false);
  expect(changes.getAttribute("aria-pressed")).toBe("true");
  // Round 1 brief: counts must be visible, including beside the icon at narrow widths.
  expect(changes.textContent).toContain("+85");
  expect(changes.textContent).toContain("-14");
  expect(changes.getAttribute("aria-label")).toBe("Changes: +85 -14");
  expect(changes.title).toBe("Changes");
  await act(async () => changes.click());
  expect(ran).toEqual(["changes"]);
  await unmount();
});

const doc = dom.window.document;
const rows = () => [...doc.querySelectorAll<HTMLElement>(".acpmux-chat-menu-popover [role=menuitem]")];
const visibleRows = () => [
  ...doc.querySelectorAll<HTMLElement>(".acpmux-chat-menu-popover:not([hidden]) [role=menuitem]"),
];

test("the chat menu lists its rows with their keys, and skips disabled rows", async () => {
  const ran: string[] = [];
  const { container, unmount } = await render({}, ran);
  const more = container.querySelector<HTMLButtonElement>('[aria-label="Chat actions"]')!;
  await act(async () => more.click());
  expect(rows().map((row) => row.textContent)).toEqual(["Rename⌘R", "Continue in", "Close"]);
  expect(doc.querySelectorAll(".acpmux-chat-menu-popover [role=separator]").length).toBe(1);
  expect(rows()[1]!.getAttribute("aria-haspopup")).toBe("menu");
  await act(async () => rows()[2]!.click());
  expect(ran).toEqual([]);
  await act(async () => rows()[0]!.click());
  expect(ran).toEqual(["rename"]);
  await unmount();
});

test("the palette's Continue in opens the menu on the harness list", async () => {
  const ran: string[] = [];
  let expanded = 0;
  const { unmount } = await render({ expand: "continue", onExpanded: () => expanded++ }, ran);
  expect(expanded).toBe(1);
  expect(visibleRows().map((row) => row.textContent)).toEqual(["Codex"]);
  await act(async () => visibleRows()[0]!.click());
  expect(ran).toEqual(["continue:codex"]);
  await unmount();
});

test("automation opens the chat menu by its label", async () => {
  const { openPicker } = await import("../pickerOpeners");
  const ran: string[] = [];
  const { unmount } = await render({}, ran);
  await act(async () => {
    expect(openPicker("Chat actions")).toBe(true);
  });
  expect(visibleRows().map((row) => row.textContent)).toEqual(["Rename⌘R", "Continue in", "Close"]);
  await unmount();
  expect(openPicker("Chat actions")).toBe(false);
});

test("Quick Chat has no tab to split, and its menu waits disabled until it has rows", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () =>
    root.render(
      createElement(ChatHeaderTools, {
        changesOpen: false,
        onChanges: () => undefined,
        onTerminal: () => undefined,
        onBrowser: () => undefined,
        tabTools: false,
        summary: null,
        menu: () => [],
      }),
    ),
  );
  const labels = [...container.querySelectorAll<HTMLButtonElement>(".acpmux-header-tools > button")].map((button) =>
    button.getAttribute("aria-label"),
  );
  expect(labels).toEqual(["Changes", "Chat actions"]);
  expect(container.querySelector<HTMLButtonElement>('[aria-label="Chat actions"]')!.disabled).toBe(true);
  await act(async () => root.unmount());
});

test("the menu opens the chat in a new window through the app's own action", () => {
  expect(HEADER_ACTIONS.newWindow).toBe("tab.moveToNewWindow");
});

// Lawrence 2026-10-09 ("continue in jank"): Continue in drew Codex and Claude Code over the parent
// menu's rows with no surface. A submenu is its own popup: portaled beside the parent, never inside
// the parent's scrolling popup, with the parent's surface class and its own positioner.
test("Continue in opens its own popup outside the parent menu, on the same surface", async () => {
  const ran: string[] = [];
  const { container, unmount } = await render({}, ran);
  const more = container.querySelector<HTMLButtonElement>('[aria-label="Chat actions"]')!;
  await act(async () => more.click());
  const trigger = rows()[1]!;
  await act(async () => {
    trigger.focus();
    trigger.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  });
  await act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
  const popups = [...doc.querySelectorAll<HTMLElement>(".ui-popup.acpmux-chat-menu-popover")];
  const parent = popups.find((popup) => popup.contains(trigger))!;
  const sub = popups.find((popup) => popup !== parent && popup.textContent?.includes("Codex"));
  expect(sub).toBeDefined();
  expect(parent.contains(sub!)).toBe(false);
  expect(sub!.closest(".ui-positioner")).not.toBe(parent.closest(".ui-positioner"));
  await unmount();
});

const press = (target: Element, key: string) =>
  act(async () => {
    const nativeDefault = target.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }),
    );
    // jsdom doesn't synthesize a button's native Enter click.
    if (key === "Enter" && nativeDefault && target instanceof dom.window.HTMLButtonElement) target.click();
    await new Promise((resolve) => setTimeout(resolve, 20));
  });

test("keyboard arrows navigate rows; Escape closes one level and restores focus", async () => {
  const { container, unmount } = await render({}, []);
  const trigger = container.querySelector<HTMLButtonElement>('[aria-label="Chat actions"]')!;
  await act(async () => trigger.focus());
  await press(trigger, "Enter");
  expect(trigger.getAttribute("aria-expanded")).toBe("true");
  await press(doc.activeElement!, "ArrowDown");
  expect(doc.activeElement?.textContent).toBe("Continue in");
  const parentItem = doc.activeElement!;
  await press(parentItem, "ArrowDown");
  expect(doc.activeElement?.textContent).toBe("Close");
  expect(doc.activeElement?.getAttribute("aria-disabled")).toBe("true");
  await press(doc.activeElement!, "ArrowUp");
  expect(doc.activeElement).toBe(parentItem);
  await press(parentItem, "ArrowRight");
  expect(doc.querySelectorAll('[role="menu"]')).toHaveLength(2);
  expect(parentItem.getAttribute("aria-expanded")).toBe("true");
  expect(doc.activeElement?.textContent).toBe("Codex");
  await press(doc.activeElement!, "Escape");
  expect(doc.querySelectorAll('[role="menu"]')).toHaveLength(1);
  expect(doc.activeElement).toBe(parentItem);
  expect(parentItem.getAttribute("aria-expanded")).toBe("false");
  await press(doc.activeElement!, "Escape");
  expect(doc.querySelector('[role="menu"]')).toBeNull();
  expect(doc.activeElement).toBe(trigger);
  await unmount();
});

test("keyboard selection runs the submenu action and returns to Chat actions", async () => {
  const ran: string[] = [];
  const { container, unmount } = await render({}, ran);
  const trigger = container.querySelector<HTMLButtonElement>('[aria-label="Chat actions"]')!;
  await act(async () => trigger.focus());
  await press(trigger, "Enter");
  await press(doc.activeElement!, "ArrowDown");
  await press(doc.activeElement!, "ArrowRight");
  await press(doc.activeElement!, "Enter");
  expect(ran).toEqual(["continue:codex"]);
  expect(doc.querySelector('[role="menu"]')).toBeNull();
  expect(doc.activeElement).toBe(trigger);
  await unmount();
});
