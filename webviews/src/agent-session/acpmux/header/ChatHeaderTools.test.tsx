import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

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

test("the chat menu lists its rows with their keys, opens submenus in place and skips disabled rows", async () => {
  const ran: string[] = [];
  const { container, unmount } = await render({}, ran);
  const more = container.querySelector<HTMLButtonElement>(".acpmux-chat-menu > button")!;
  await act(async () => more.click());
  const rows = () => [...container.querySelectorAll<HTMLButtonElement>("[role=menuitem]")];
  expect(rows().map((row) => row.textContent)).toEqual(["Rename⌘R", "Continue in", "Close"]);
  expect(container.querySelectorAll(".acpmux-chat-menu-separator").length).toBe(1);
  await act(async () => rows()[1]!.click());
  expect(rows().map((row) => row.textContent)).toEqual(["Rename⌘R", "Continue in", "Codex", "Close"]);
  await act(async () => rows()[3]!.click());
  expect(ran).toEqual([]);
  await act(async () => rows()[2]!.click());
  expect(ran).toEqual(["continue:codex"]);
  expect(container.querySelector("[role=menu]")).toBeNull();
  await act(async () => more.click());
  await act(async () => rows()[0]!.click());
  expect(ran).toEqual(["continue:codex", "rename"]);
  await unmount();
});
