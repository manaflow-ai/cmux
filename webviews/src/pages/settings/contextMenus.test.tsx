// Settings > Menus (ContextMenusCard): the person arranges each right-click menu as a tree, so any
// row goes anywhere at any depth. Customize Menu… opens the page on its menu; a row moves to any
// submenu (Move to…) or by drag (before or after any row, into a submenu's middle); a submenu moves
// into another with its rows; rows hide and show in place; the person makes, names, fills and
// deletes their own submenus; separators add and go; Reset saves no layout. Every change saves the
// whole tree through cmux.settings.context_menus.set.
import { afterAll, expect, test } from "bun:test";
import type { MenuLayout, MenuNode } from "./ops";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click, ops, changeValue, fire } = await import("./testing");
const { act } = await import("react");

const SET = "cmux.settings.context_menus.set";

const editor = (container: HTMLElement) => container.querySelector<HTMLElement>('[data-card="context-menus"]')!;
const row = (container: HTMLElement, key: string) =>
  editor(container).querySelector<HTMLElement>(`.menu-row[data-key="${key}"]`)!;
const drawn = (container: HTMLElement) =>
  [...editor(container).querySelectorAll<HTMLElement>(".menu-preview > [data-flat]")].map(
    (element) => `${element.dataset.depth}:${element.dataset.key ?? "-"}`,
  );
const action = (element: HTMLElement, name: string) =>
  element.querySelector<HTMLButtonElement>(`[data-action="${name}"]`)!;
const saved = (provider: Parameters<typeof ops>[0]) =>
  (ops(provider, SET).at(-1) as { menu: string; layout: MenuLayout | null }).layout;

/** The rows of submenu `key` in `nodes`, at any depth. */
function folder(nodes: MenuNode[], key: string): MenuNode[] | undefined {
  for (const node of nodes) {
    if (typeof node !== "object") continue;
    if (node.key === key) return node.items;
    const found = folder(node.items, key);
    if (found) return found;
  }
  return undefined;
}
const keys = (nodes: MenuNode[] | undefined) =>
  (nodes ?? []).map((node) => (typeof node === "object" ? node.key : node));

/** Move to… on `key`'s row, then the destination labelled `label` (the page's list in tests). */
async function moveTo(container: HTMLElement, key: string, label: string) {
  await click(action(row(container, key), "move-to"));
  const choice = [...editor(container).querySelectorAll<HTMLButtonElement>("[data-destination]")].find(
    (button) => button.textContent === label,
  );
  expect(choice).toBeDefined();
  await click(choice!);
}

/** Lays the drawn rows out 24 px apart from y = 100, as the page draws them (jsdom has no layout). */
function layOut(container: HTMLElement) {
  const list = editor(container).querySelector<HTMLElement>(".menu-preview")!;
  const box = (top: number) => () =>
    ({
      top,
      bottom: top + 24,
      left: 0,
      right: 400,
      width: 400,
      height: 24,
      x: 0,
      y: top,
      toJSON: () => ({}),
    }) as DOMRect;
  list.getBoundingClientRect = box(100);
  list.querySelectorAll<HTMLElement>(":scope > [data-flat]").forEach((element, position) => {
    element.getBoundingClientRect = box(100 + position * 24);
  });
}
const rowY = (container: HTMLElement, key: string) =>
  [...editor(container).querySelectorAll<HTMLElement>(".menu-preview > [data-flat]")].findIndex(
    (element) => element.dataset.key === key,
  ) *
    24 +
  100;

/** Where `key`'s row shows while `dragged` (one row) is lifted out: the rows below it move up a row. */
const liftedY = (container: HTMLElement, key: string, dragged: string) =>
  rowY(container, key) - (rowY(container, key) > rowY(container, dragged) ? 24 : 0);

/** Presses `key`'s grip, moves the pointer to `y` (and `dx` sideways), then releases: the person's drag. */
async function dragRow(container: HTMLElement, key: string, y: number, check?: () => void, dx = 0) {
  layOut(container);
  const grip = row(container, key).querySelector<HTMLElement>(".menu-row-grip")!;
  const pointer = (type: string, clientY: number, clientX = 40) =>
    act(async () => {
      grip.dispatchEvent(new window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX, clientY }));
    });
  const start = rowY(container, key) + 12;
  await pointer("pointerdown", start);
  await pointer("pointermove", start + (y > start ? 6 : -6));
  await pointer("pointermove", y, 40 + dx);
  check?.();
  await pointer("pointerup", y, 40 + dx);
  await settle();
}

test("Customize Menu… opens Settings > Menus on its menu", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=tab" });
  await settle();
  expect(editor(page.container).dataset.menu).toBe("tab");
  expect(editor(page.container).querySelector(".menus-detail-title")?.textContent).toBe("Tab");
  await click(editor(page.container).querySelector<HTMLElement>('.menus-list-item[data-menu="terminalSelection"]')!);
  expect(editor(page.container).dataset.menu).toBe("terminalSelection");
  page.unmount();
});

test("the editor draws the whole tree: each open submenu's rows indented under it", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  // More is open; Move and Options are closed until opened.
  expect(drawn(page.container)).toContain("1:workspace.copyPath");
  expect(drawn(page.container)).not.toContain("1:palette.moveWorkspaceToTop");
  await click(action(editor(page.container), "expand"));
  expect(drawn(page.container)).toContain("1:palette.moveWorkspaceToTop");
  expect(drawn(page.container)).toContain("2:palette.markWorkspaceUnread");
  page.unmount();
});

test("Move to… takes any row to any submenu at any depth, or out to the top level", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  // Out of More to the top level.
  await moveTo(page.container, "workspace.copyPath", "Top Level");
  expect(keys(saved(page.provider)?.items)).toContain("workspace.copyPath");
  expect(keys(folder(saved(page.provider)!.items, "folder:more"))).not.toContain("workspace.copyPath");
  // A top-level row into Move ▸.
  await moveTo(page.container, "renameWorkspace", "Move");
  expect(keys(folder(saved(page.provider)!.items, "folder:move")).at(-1)).toBe("renameWorkspace");
  // A submenu into a submenu inside another: Move ▸ into More › Options, rows and all.
  await moveTo(page.container, "folder:move", "More › Options");
  const options = folder(saved(page.provider)!.items, "folder:options");
  expect(keys(options)).toContain("folder:move");
  expect(keys(folder(options!, "folder:move"))).toEqual([
    "palette.moveWorkspaceToTop",
    "palette.moveWorkspaceToBottom",
    "renameWorkspace",
  ]);
  expect(keys(saved(page.provider)?.items)).not.toContain("folder:move");
  page.unmount();
});

test("a submenu never moves into itself", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  await click(action(row(page.container, "folder:more"), "move-to"));
  const labels = [...editor(page.container).querySelectorAll("[data-destination]")].map((button) => button.textContent);
  expect(labels).toContain("Move");
  expect(labels).not.toContain("More");
  expect(labels).not.toContain("More › Options");
  page.unmount();
});

test("dragging a row onto a closed submenu's name puts it in that submenu", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  // Rename lifted out, Move ▸ shows a row higher: its middle there.
  await dragRow(
    page.container,
    "renameWorkspace",
    liftedY(page.container, "folder:move", "renameWorkspace") + 12,
    () => {
      expect(row(page.container, "folder:move").hasAttribute("data-drop-into")).toBe(true);
    },
  );
  expect(keys(folder(saved(page.provider)!.items, "folder:move")).at(-1)).toBe("renameWorkspace");
  // The submenu opens to show where it went.
  expect(drawn(page.container)).toContain("1:renameWorkspace");
  page.unmount();
});

test("dragging a row between two rows of an open submenu puts it there, the gap opening there", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  // Between Copy Path and Reveal in Finder, More's first two rows.
  await dragRow(
    page.container,
    "renameWorkspace",
    liftedY(page.container, "revealWorkspaceInFinder", "renameWorkspace"),
    () => {
      // The gap opens under Copy Path: Reveal moves down into its old place, Copy Path stays up.
      expect(row(page.container, "revealWorkspaceInFinder").style.transform).toBe("");
      expect(row(page.container, "workspace.copyPath").style.transform).toBe("translateY(-24px)");
      // The dragged row moves one level in, to the depth it lands at.
      expect(row(page.container, "renameWorkspace").style.transform).toContain("translate(18px");
    },
  );
  expect(keys(folder(saved(page.provider)!.items, "folder:more"))).toEqual([
    "workspace.copyPath",
    "renameWorkspace",
    "revealWorkspaceInFinder",
    "folder:options",
  ]);
  page.unmount();
});

test("at the end of a submenu, sideways travel picks inside it or after it", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  // Just under More's last row (Options ▸) and above the separator after More.
  const end = liftedY(page.container, "folder:options", "renameWorkspace") + 26;
  await dragRow(page.container, "renameWorkspace", end, undefined, 18);
  expect(keys(folder(saved(page.provider)!.items, "folder:more")).at(-1)).toBe("renameWorkspace");
  page.unmount();

  const again = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  await dragRow(again.container, "renameWorkspace", liftedY(again.container, "folder:options", "renameWorkspace") + 26);
  const top = keys(saved(again.provider)?.items);
  expect(top.indexOf("renameWorkspace")).toBe(top.indexOf("folder:more") + 1);
  expect(keys(folder(saved(again.provider)!.items, "folder:more"))).not.toContain("renameWorkspace");
  again.unmount();
});

test("dragging a row out of a submenu puts it where it is dropped, the gap opening there", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  // Copy Path (in More) dragged above the first row: every row from there down slides one row.
  await dragRow(page.container, "workspace.copyPath", 102, () => {
    expect(row(page.container, "renameWorkspace").style.transform).toBe("translateY(24px)");
    expect(row(page.container, "workspace.copyPath").hasAttribute("data-dragging")).toBe(true);
  });
  expect(keys(saved(page.provider)?.items)[0]).toBe("workspace.copyPath");
  page.unmount();
});

test("a top-level row drags past others, which slide to open its gap", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=terminalSelection" });
  await settle();
  expect(row(page.container, "copy").getAttribute("draggable")).toBeNull();
  await dragRow(page.container, "clearTerminal", 102, () => {
    expect(row(page.container, "copy").style.transform).toBe("translateY(24px)");
    expect(row(page.container, "splitDown").style.transform).toBe("translateY(24px)");
  });
  expect(keys(saved(page.provider)?.items).slice(0, 2)).toEqual(["clearTerminal", "copy"]);
  // A row dropped back where it started saves nothing.
  const before = ops(page.provider, SET).length;
  await dragRow(page.container, "paste", rowY(page.container, "paste") + 12);
  expect(ops(page.provider, SET).length).toBe(before);
  page.unmount();
});

test("a hidden row stays in place, dimmed, and Show brings it back there", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  const before = drawn(page.container);
  await click(action(row(page.container, "workspace.duplicate"), "hide"));
  expect(saved(page.provider)?.hidden).toEqual(["workspace.duplicate"]);
  expect(row(page.container, "workspace.duplicate").hasAttribute("data-hidden")).toBe(true);
  expect(drawn(page.container)).toEqual(before);
  await click(action(row(page.container, "workspace.duplicate"), "hide"));
  // Back as the app made it: no layout at all.
  expect(saved(page.provider)).toBeNull();
  expect(row(page.container, "workspace.duplicate").hasAttribute("data-hidden")).toBe(false);
  page.unmount();
});

test("the person makes a submenu, names it, fills it and deletes it", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  await click(action(editor(page.container), "new-submenu"));
  const made = saved(page.provider)!.items.at(-1) as { key: string; title: string; items: MenuNode[] };
  expect(made.key.startsWith("group:")).toBe(true);
  // It opens as a name field.
  const field = editor(page.container).querySelector<HTMLInputElement>(".menu-rename")!;
  expect(field).not.toBeNull();
  await changeValue(field, "Mine");
  await fire(field, "keydown", { key: "Enter" });
  expect((saved(page.provider)!.items.at(-1) as { title: string }).title).toBe("Mine");
  // Rows go into it, a submenu of the app's too.
  await moveTo(page.container, "renameWorkspace", "Mine");
  await moveTo(page.container, "folder:move", "Mine");
  expect(keys(folder(saved(page.provider)!.items, made.key))).toEqual(["renameWorkspace", "folder:move"]);
  // Deleting it leaves its rows where it was.
  await click(action(row(page.container, made.key), "delete"));
  const items = keys(saved(page.provider)?.items);
  expect(items).not.toContain(made.key);
  expect(items.slice(-2)).toEqual(["renameWorkspace", "folder:move"]);
  page.unmount();
});

test("separators add and go, and Reset brings back the app's menu", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=terminalSelection" });
  await settle();
  const reset = () => action(editor(page.container), "reset");
  expect(reset().disabled).toBe(true);
  await click(action(editor(page.container), "add-separator"));
  expect(saved(page.provider)?.items.at(-1)).toBe("-");
  expect(reset().disabled).toBe(false);
  const separator = editor(page.container).querySelector<HTMLElement>(".menu-separator")!;
  await click(action(separator, "remove"));
  expect(keys(saved(page.provider)?.items)).toEqual([
    "copy",
    "paste",
    "splitRight",
    "splitDown",
    "-",
    "clearTerminal",
    "-",
  ]);
  await click(reset());
  expect(saved(page.provider)).toBeNull();
  page.unmount();
});

test("a row button's tooltip names only its action", async () => {
  const page = await renderPage({ path: "/settings/menus?focus=workspaceRow" });
  await settle();
  const moveToButton = action(row(page.container, "renameWorkspace"), "move-to");
  expect(moveToButton.title).toBe("Move to…");
  expect(moveToButton.getAttribute("aria-label")).toBe("Move to…: Rename Workspace…");
  page.unmount();
});

test("the Customize Menu… switch turns the row off in every menu", async () => {
  const page = await renderPage({ path: "/settings/menus" });
  await settle();
  const toggle = page.container.querySelector<HTMLElement>('[data-card="context-menus-options"] [role="switch"]')!;
  expect(toggle.getAttribute("aria-checked")).toBe("true");
  await click(toggle);
  expect(ops(page.provider, "cmux.settings.context_menus.show_item")).toEqual([{ show: false }]);
  expect(toggle.getAttribute("aria-checked")).toBe("false");
  page.unmount();
});
