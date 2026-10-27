import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { guardedChatMenu, menuItemForShortcut, type ChatMenuItem } from "./ChatHeaderTools";
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
  { key: "rename", label: "Rename", icon: "action.edit", shortcutLabel: "R", onSelect: () => undefined },
  { key: "delete", label: "Delete", icon: "tab.close", disabled: true, shortcutLabel: "D" },
];

test("the chat title is a labelled, keyboard-focusable menu trigger", async () => {
  const container = installDom();
  root = createRoot(container);
  await act(async () => {
    root!.render(<ThreadTitle title="Phone to computer connection" menu={rows} />);
  });
  const trigger = container.querySelector<HTMLButtonElement>(".acpmux-thread-title-trigger");
  expect(trigger).not.toBeNull();
  expect(trigger?.getAttribute("aria-label")).toBe("Phone to computer connection");
  expect(trigger?.title).toBe("Phone to computer connection");
  expect(trigger?.textContent).toContain("Phone to computer connection");
  expect(trigger?.querySelector(".acpmux-thread-title-chevron")).not.toBeNull();
});

test("opens before a native refresh resolves and refreshes the visible rows", async () => {
  const container = installDom();
  root = createRoot(container);
  let refreshed = false;
  let finish!: () => void;
  const refresh = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const dynamicRows = (): ChatMenuItem[] => [
    { key: "rename", label: refreshed ? "Fresh Rename" : "Stale Rename", icon: "action.edit" },
  ];
  await act(async () => {
    root!.render(<ThreadTitle title="A chat" menu={dynamicRows} onMenuOpen={() => refresh} />);
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-thread-title-trigger")!.click());
  expect(document.querySelector('[role="menu"]')?.textContent).toContain("Stale Rename");
  refreshed = true;
  await act(async () => {
    finish();
    await refresh;
  });
  expect(document.querySelector('[role="menu"]')?.textContent).toContain("Fresh Rename");
});

test("a title-menu letter invokes its action and a late refresh cannot reopen it", async () => {
  const container = installDom();
  root = createRoot(container);
  let selected = 0;
  let finish!: () => void;
  const refresh = new Promise<void>((resolve) => {
    finish = resolve;
  });
  await act(async () =>
    root!.render(
      <ThreadTitle
        title="A chat"
        onMenuOpen={() => refresh}
        menu={() => [
          { key: "rename", label: "Rename", icon: "action.edit", shortcutLabel: "R", onSelect: () => selected++ },
        ]}
      />,
    ),
  );
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-thread-title-trigger")!.click());
  await act(async () =>
    document
      .querySelector('[role="menu"]')!
      .dispatchEvent(new KeyboardEvent("keydown", { key: "r", bubbles: true, cancelable: true })),
  );
  expect(selected).toBe(1);
  await act(async () => {
    finish();
    await refresh;
  });
  expect(document.querySelector('[role="menu"]')).toBeNull();
});

test("resolves explicit title-menu shortcut letters", () => {
  let selected = 0;
  const item = menuItemForShortcut(
    [{ key: "rename", label: "Rename", icon: "action.edit", shortcutLabel: "R", onSelect: () => selected++ }],
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
