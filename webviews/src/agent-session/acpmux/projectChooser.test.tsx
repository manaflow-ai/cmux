import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

// The row's own stylesheet, so a test reads the truncation the cascade gives the label.
const locationCss = readFileSync(new URL("./composerLocation.css", import.meta.url), "utf8");
const dom = new JSDOM(`<!doctype html><style>${locationCss}</style><div id=root></div>`, {
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
// The pickers are shared Base UI components (src/ui), which reach for DOM classes by name.
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
const { ComposerContext } = await import("./ComposerContext");

const sessions: AcpmuxSnapshot["sessions"] = [
  { sessionId: "local", cwd: "/Users/me/code/cmux", host: "This Mac", hostKind: "local" },
  { sessionId: "cloud", cwd: "/workspace/cmux", host: "devbox", hostKind: "cloud" },
];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
let picked: Array<[string, string | undefined]>;
let browsed = 0;

beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
  picked = [];
  browsed = 0;
});
afterEach(async () => act(async () => root.unmount()));

const render = (
  summary: Partial<Summary> = {},
  started = false,
  projectChoices?: { cwd: string; label: string }[],
  chats: AcpmuxSnapshot["sessions"] = sessions,
) =>
  act(async () =>
    root.render(
      createElement(ComposerContext, {
        summary: {
          sessionId: "s",
          cwd: "/Users/me/code/cmux",
          host: "This Mac",
          hostKind: "local",
          ...summary,
        },
        sessions: chats,
        started,
        projectChoices,
        onBrowseProject: () => browsed++,
        onProject: (cwd: string, peer?: string) => picked.push([cwd, peer]),
      }),
    ),
  );

test("renders the attached folder, computer and branch tray without context chips", async () => {
  await render({ branch: "main" });
  expect(doc.querySelectorAll(".acpmux-context-chip")).toHaveLength(0);
  expect([...doc.querySelectorAll(".acpmux-location-button")].map((button) => button.textContent)).toEqual([
    "cmux",
    "This Mac",
    "main",
  ]);
  expect(doc.querySelector(".acpmux-composer-context")).not.toBeNull();
  // Folder and branch icons plus the shared chevrons keep the controls aligned.
  expect(doc.querySelectorAll(".acpmux-location-button .acpmux-icon").length).toBeGreaterThanOrEqual(3);

  const branch = doc.querySelector<HTMLButtonElement>('[aria-label="Branch"]')!;
  await act(async () => branch.click());
  const branchRow = doc.querySelector<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')!;
  expect([
    branchRow.textContent,
    branchRow.getAttribute("aria-checked"),
    branchRow.getAttribute("aria-disabled"),
  ]).toEqual(["✓main", "true", "true"]);
});

test("offers Cloud computers and sends the selected computer with its folder", async () => {
  await render();
  const computer = doc.querySelector<HTMLButtonElement>('[aria-label="Computer"]')!;
  await act(async () => computer.click());
  expect(
    // The computer menu is a shared radio menu (src/ui Menu): its items are menuitemradio rows.
    [...doc.querySelectorAll('.acpmux-location-menu [role="menuitemradio"]')].map((row) =>
      row.textContent?.replace("✓", ""),
    ),
  ).toEqual(["This Mac", "devboxCloud"]);
  await act(async () => doc.querySelectorAll<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')[1]!.click());
  const folder = doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!;
  expect(folder.textContent).toContain("cmux");
  await act(async () => folder.click());
  expect(picked).toEqual([["/workspace/cmux", "devbox"]]);
});

test("locks both location labels after the first turn", async () => {
  await render({ turnCount: 1, branch: "main" }, true);
  expect(doc.querySelectorAll(".acpmux-location-button")).toHaveLength(1);
  expect(doc.querySelector('.acpmux-location-button[aria-label="Branch"]')).not.toBeNull();
  expect(doc.querySelectorAll(".acpmux-location-readonly")).toHaveLength(2);
  expect(doc.querySelector(".acpmux-composer-context")?.getAttribute("data-readonly")).toBe("true");
});

test("the folder picker takes a typed absolute path on Return", async () => {
  await render();
  await act(async () => doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!.click());
  const field = doc.querySelector<HTMLInputElement>(".acpmux-location-search")!;
  expect(field).not.toBeNull();
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, "/tmp/scratch");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(picked.at(-1)?.[0]).toBe("/tmp/scratch");
});

test("folder rows show the project name over its path, and typing filters on both", async () => {
  await render();
  await act(async () => doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!.click());
  const rows = () =>
    [...doc.querySelectorAll('.acpmux-location-menu [role="option"]')].map((row) => [
      row.querySelector(".acpmux-menu-label")?.textContent,
      row.querySelector(".acpmux-menu-description")?.textContent,
    ]);
  expect(rows()).toEqual([["cmux", "/Users/me/code/cmux"]]);
  const field = doc.querySelector<HTMLInputElement>(".acpmux-location-search")!;
  const type = (text: string) =>
    act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, text);
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  await type("code");
  expect(rows()).toEqual([["cmux", "/Users/me/code/cmux"]]);
  await type("nothing-matches");
  expect(rows()).toEqual([]);
});

const freshFolders = [
  { cwd: "/Users/me/code/cmux", label: "cmux" },
  { cwd: "/Users/me/Projects/relay", label: "relay" },
];
const folderButton = () => doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!;
const folderRows = () =>
  [...doc.querySelectorAll('.acpmux-location-menu [role="menuitemradio"]')].map((row) => [
    row.querySelector(".acpmux-menu-label")?.textContent,
    row.querySelector(".acpmux-menu-description")?.textContent,
    row.getAttribute("aria-checked"),
  ]);
const menuItems = () =>
  [...doc.querySelectorAll('.acpmux-location-menu [role="menuitem"]')].map((item) => item.textContent);

test("the fresh-chat folder menu lists the recent folders, the current one checked, then Choose folder…", async () => {
  await render({}, false, freshFolders);
  const button = folderButton();
  expect(button.textContent).toBe("cmux");
  expect(button.closest("[title]")?.getAttribute("title")).toBe("/Users/me/code/cmux");
  await act(async () => button.click());
  expect(folderRows()).toEqual([
    ["cmux", "/Users/me/code/cmux", "true"],
    ["relay", "/Users/me/Projects/relay", "false"],
  ]);
  expect(menuItems()).toEqual(["Choose folder…"]);
  // The folder list comes first and Choose folder… last, under a separator.
  const menu = doc.querySelector(".acpmux-location-menu")!;
  const order = [...menu.querySelectorAll('[role="menuitemradio"], [role="separator"], [role="menuitem"]')].map(
    (node) => node.getAttribute("role"),
  );
  expect(order).toEqual(["menuitemradio", "menuitemradio", "separator", "menuitem"]);
  await act(async () => doc.querySelectorAll<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')[1]!.click());
  expect(picked).toEqual([["/Users/me/Projects/relay", undefined]]);
});

test("Choose folder… asks the host for its folder panel from the click", async () => {
  await render({}, false, freshFolders);
  await act(async () => folderButton().click());
  await act(async () => doc.querySelector<HTMLElement>('.acpmux-location-menu [role="menuitem"]')!.click());
  expect(browsed).toBe(1);
  expect(picked).toEqual([]);
  expect(doc.querySelector(".acpmux-location-menu")).toBeNull();
});

test("picking the current folder only closes the menu", async () => {
  await render({}, false, freshFolders);
  await act(async () => folderButton().click());
  await act(async () => doc.querySelector<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')!.click());
  expect(picked).toEqual([]);
});

test("with no folder the button reads Choose folder in the same face, and its menu offers only Choose folder…", async () => {
  await render({ cwd: undefined }, false, [], []);
  const button = folderButton();
  expect(button.textContent).toBe("Choose folder");
  expect(button.className).toBe(doc.querySelector('[aria-label="Computer"]')!.className);
  expect(button.querySelector(".acpmux-location-label")).not.toBeNull();
  expect(button.closest("[title]")).toBeNull();
  await act(async () => button.click());
  expect(folderRows()).toEqual([]);
  expect(doc.querySelectorAll('.acpmux-location-menu [role="separator"]')).toHaveLength(0);
  expect(menuItems()).toEqual(["Choose folder…"]);
});

test("a long folder name is cut with an ellipsis on one line, and the tooltip keeps the full path", async () => {
  const cwd = "/Users/me/code/a-really-long-project-folder-name-that-overflows-the-row";
  await render({ cwd }, false, [{ cwd, label: "a-really-long-project-folder-name-that-overflows-the-row" }]);
  const label = folderButton().querySelector<HTMLElement>(".acpmux-location-label")!;
  expect(label.textContent).toBe("a-really-long-project-folder-name-that-overflows-the-row");
  const style = dom.window.getComputedStyle(label);
  expect([style.overflow, style.textOverflow, style.whiteSpace]).toEqual(["hidden", "ellipsis", "nowrap"]);
  expect(folderButton().closest("[title]")?.getAttribute("title")).toBe(cwd);
});

test("the keyboard opens the folder menu, moves through it and picks with Enter", async () => {
  await render({}, false, freshFolders);
  const button = folderButton();
  await act(async () => button.focus());
  expect(doc.activeElement).toBe(button);
  await act(async () => {
    button.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }),
    );
  });
  expect(doc.querySelector(".acpmux-location-menu")).not.toBeNull();
  const key = (name: string) =>
    act(async () => {
      (doc.activeElement ?? button).dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }),
      );
    });
  await key("ArrowDown");
  await key("ArrowDown");
  await key("ArrowDown");
  expect((doc.activeElement as HTMLElement | null)?.textContent).toBe("Choose folder…");
  await key("Enter");
  expect(browsed).toBe(1);
});

test("keeps the root project selectable", async () => {
  await render({ cwd: undefined }, false, [{ cwd: "/", label: "Root" }]);
  await act(async () => folderButton().click());
  await act(async () => doc.querySelector<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')!.click());
  expect(picked).toEqual([["/", undefined]]);
});

test("automation opens the Location and Computer menus by their labels, as a click does", async () => {
  const { openPicker, pickerLabels } = await import("./pickerOpeners");
  // The fresh-chat folder menu.
  await render({}, false, [{ cwd: "/Users/me/code/cmux", label: "cmux" }]);
  expect(pickerLabels()).toEqual(expect.arrayContaining(["Location", "Computer"]));
  let opened = false;
  await act(async () => {
    opened = openPicker("Location");
  });
  expect(opened).toBe(true);
  expect(folderButton().getAttribute("aria-expanded")).toBe("true");
  expect(doc.querySelectorAll('.acpmux-location-menu [role="menuitemradio"]').length).toBeGreaterThan(0);
  // The folder field of a chat with no project choices.
  await act(async () => root.unmount());
  root = createRoot(doc.getElementById("root")!);
  await render();
  await act(async () => {
    openPicker("Location");
  });
  expect(doc.querySelector(".acpmux-location-search")).not.toBeNull();
  await act(async () => {
    openPicker("Computer");
  });
  expect(doc.querySelector<HTMLButtonElement>('[aria-label="Computer"]')!.getAttribute("aria-expanded")).toBe("true");
  // A started chat's location is a label: nothing to open.
  await act(async () => root.unmount());
  root = createRoot(doc.getElementById("root")!);
  await render({ turnCount: 1 }, true);
  expect(pickerLabels()).not.toContain("Location");
  expect(openPicker("Location")).toBe(false);
});
