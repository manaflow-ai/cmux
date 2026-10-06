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
  expect(changes.textContent).toContain("+0");
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
  expect(changes.textContent).toContain("+85");
  expect(changes.textContent).toContain("14");
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
