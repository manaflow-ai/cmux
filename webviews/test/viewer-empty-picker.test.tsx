// The fallback path picker's interaction (PathPicker.tsx, the palette picker's reference): one
// level at a time, recent folders first, git repositories marked, fuzzy filter, Tab and Right
// enter, Left, Backspace and Cmd-Up go up, Enter chooses, / and ~/ are path mode, Locations sit
// above the level, the breadcrumb navigates.
import {
  click,
  doubleClick,
  mouseDown,
  press,
  render,
  installDom,
  restoreDom,
  type,
  unmount,
} from "./viewer-empty-dom";
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import type { PickerEntry, PickerListing, PickerMode } from "../src/viewer-empty/ops";
import { PathPicker } from "../src/viewer-empty/PathPicker";
import { viewerEmptyStrings } from "../src/viewer-empty/strings";

afterEach(() => unmount());
beforeAll(() => installDom());
afterAll(() => restoreDom());

const strings = viewerEmptyStrings(["en"]);
const HOME = "/Users/me";

/** A small file system: folder path -> entries. */
const TREE: Record<string, Array<Omit<PickerEntry, "path">>> = {
  "/": [
    { name: "Users", kind: "dir" },
    { name: "tmp", kind: "dir" },
  ],
  "/Users": [{ name: "me", kind: "dir" }],
  [HOME]: [
    { name: "Documents", kind: "dir" },
    { name: "fun", kind: "dir" },
    { name: "notes.md", kind: "file" },
    { name: ".config", kind: "dir" },
    { name: "zeta", kind: "dir" },
  ],
  [`${HOME}/fun`]: [
    { name: "cmuxterm-hq", kind: "dir", git: true },
    { name: "chatmux", kind: "dir", git: true },
    { name: "scratch", kind: "dir" },
    { name: "README.md", kind: "file" },
  ],
  [`${HOME}/fun/scratch`]: [],
  [`${HOME}/Documents`]: [{ name: "plan.md", kind: "file" }],
  [`${HOME}/.config`]: [{ name: "cmux", kind: "dir" }],
  "/tmp": [],
};

function fakeList() {
  const calls: Array<{ path: string | null; mode: PickerMode; hidden: boolean }> = [];
  const list = async (path: string | null, options: { mode: PickerMode; hidden: boolean }): Promise<PickerListing> => {
    calls.push({ path, ...options });
    const dir = path == null || path === "~" ? HOME : path;
    const entries = TREE[dir];
    if (!entries) throw new Error(`no such folder ${dir}`);
    return {
      path: dir,
      parent: dir === "/" ? null : dir.slice(0, dir.lastIndexOf("/")) || "/",
      home: HOME,
      entries: entries
        .filter((entry) => options.hidden || !entry.name.startsWith("."))
        .filter((entry) => entry.kind === "dir" || options.mode === "file")
        .map((entry) => ({ ...entry, path: `${dir === "/" ? "" : dir}/${entry.name}` })),
    };
  };
  return { list, calls };
}

async function mountPicker(options: { mode?: PickerMode; recents?: string[]; start?: string | null } = {}) {
  const chosen: string[] = [];
  let cancelled = 0;
  const { list, calls } = fakeList();
  const container = await render(
    <PathPicker
      mode={options.mode ?? "folder"}
      list={list}
      strings={strings}
      recents={options.recents}
      start={options.start ?? null}
      onChoose={(path) => chosen.push(path)}
      onCancel={() => (cancelled += 1)}
    />,
  );
  const field = () => container.querySelector<HTMLInputElement>(".ve-picker-field")!;
  const names = () => [...container.querySelectorAll(".ve-picker-name")].map((node) => node.textContent);
  const highlighted = () =>
    container.querySelector('.ve-picker-row[aria-selected="true"] .ve-picker-name')?.textContent;
  const crumbs = () => [...container.querySelectorAll(".ve-crumb")].map((node) => node.textContent);
  // The rows of the level (not the Locations section above it).
  const levelRows = () => [...container.querySelectorAll<HTMLElement>(".ve-picker-row:not([data-location])")];
  const locations = () => [...container.querySelectorAll(".ve-picker-location")].map((node) => node.textContent);
  return {
    container,
    field,
    names,
    highlighted,
    crumbs,
    levelRows,
    locations,
    chosen,
    calls,
    cancelled: () => cancelled,
  };
}

describe("path picker", () => {
  test("lists one level of folders, hidden ones left out, starting at home", async () => {
    const picker = await mountPicker();
    expect(picker.calls[0]).toEqual({ path: null, mode: "folder", hidden: false });
    expect(picker.names()).toEqual(["Documents", "fun", "zeta"]);
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.highlighted()).toBe("Documents");
    expect(document.activeElement).toBe(picker.field());
  });

  test("recent folders sort first and git repositories are marked", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun`, recents: [`${HOME}/fun/scratch`] });
    expect(picker.names()).toEqual(["scratch", "chatmux", "cmuxterm-hq"]);
    const rows = picker.levelRows();
    expect(rows[0].dataset.recent).toBe("true");
    expect(rows.map((row) => row.dataset.git ?? "")).toEqual(["", "true", "true"]);
    expect(rows[1].querySelector(".ve-icon-repo")).toBeTruthy();
  });

  test("typing filters the level fuzzily; Down moves and Enter chooses the highlighted folder", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await type(picker.field(), "chq");
    expect(picker.names()).toEqual(["cmuxterm-hq"]);
    await type(picker.field(), "c");
    expect(picker.names()).toEqual(["chatmux", "cmuxterm-hq", "scratch"]);
    await press(picker.field(), "ArrowDown");
    expect(picker.highlighted()).toBe("cmuxterm-hq");
    await press(picker.field(), "Enter");
    expect(picker.chosen).toEqual([`${HOME}/fun/cmuxterm-hq`]);
  });

  test("Tab and Right enter the highlighted folder; Left and Backspace on an empty query go up", async () => {
    const picker = await mountPicker();
    await press(picker.field(), "ArrowDown"); // fun
    await press(picker.field(), "Tab");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    expect(picker.names()).toEqual(["chatmux", "cmuxterm-hq", "scratch"]);
    await press(picker.field(), "ArrowDown");
    await press(picker.field(), "ArrowDown"); // scratch
    await press(picker.field(), "ArrowRight");
    expect(picker.crumbs()).toEqual(["~", "fun", "scratch"]);
    expect(picker.container.querySelector(".ve-picker-empty")?.textContent).toBe("No folders here");
    await press(picker.field(), "ArrowLeft");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    // Going up highlights the folder it came from.
    expect(picker.highlighted()).toBe("scratch");
    await press(picker.field(), "Backspace");
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.highlighted()).toBe("fun");
  });

  test("Right and Left move the caret inside a query instead of navigating", async () => {
    const picker = await mountPicker();
    await type(picker.field(), "fu");
    picker.field().setSelectionRange(1, 1);
    await press(picker.field(), "ArrowRight");
    await press(picker.field(), "ArrowLeft");
    expect(picker.crumbs()).toEqual(["~"]);
    // Backspace with text edits the text.
    await press(picker.field(), "Backspace");
    expect(picker.crumbs()).toEqual(["~"]);
  });

  test("path mode: / and ~/ list a typed path; ~ alone is text; name/ enters that folder", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await type(picker.field(), "/");
    expect(picker.crumbs()).toEqual(["/"]);
    expect(picker.names()).toEqual(["tmp", "Users"]);
    // The field keeps the path; the last part filters the folder.
    expect(picker.field().value).toBe("/");
    await type(picker.field(), "/U");
    expect(picker.names()).toEqual(["Users"]);
    // Tab enters and the field follows the folder.
    await press(picker.field(), "Tab");
    expect(picker.crumbs()).toEqual(["/", "Users"]);
    expect(picker.field().value).toBe("/Users/");
    await type(picker.field(), "~");
    expect(picker.crumbs()).toEqual(["/", "Users"]);
    expect(picker.container.querySelector(".ve-picker-empty")?.textContent).toBe("No matches");
    await type(picker.field(), "~/fu");
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.names()).toEqual(["fun"]);
    // Cmd-Up goes to the parent and keeps path mode.
    await press(picker.field(), "ArrowUp", { metaKey: true });
    expect(picker.crumbs()).toEqual(["/", "Users"]);
    expect(picker.field().value).toBe("/Users/");
    await type(picker.field(), "");
    await type(picker.field(), "me/");
    expect(picker.crumbs()).toEqual(["~"]);
  });

  test("Locations: home, the root and recent folders while the query is empty", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun`, recents: [`${HOME}/fun/scratch`, "/tmp"] });
    expect(picker.locations()).toEqual(["Home", "Computer", "scratch", "tmp"]);
    expect(picker.container.querySelector(".ve-picker-section")?.textContent).toBe("Locations");
    // The level's first row is highlighted; Up moves into Locations; Enter there opens it.
    expect(picker.highlighted()).toBe("scratch");
    for (let index = 0; index < 4; index += 1) await press(picker.field(), "ArrowUp");
    await press(picker.field(), "Enter");
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.chosen).toEqual([]);
    await type(picker.field(), "f");
    expect(picker.locations()).toEqual([]);
  });

  test("Cmd-Up goes up; other Cmd chords reach the app", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await press(picker.field(), "ArrowUp", { metaKey: true });
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.highlighted()).toBe("fun");
    let reached = 0;
    const listener = (event: Event) => {
      if (!event.defaultPrevented) reached += 1;
    };
    document.addEventListener("keydown", listener);
    await press(picker.field(), "s", { metaKey: true });
    await press(picker.field(), "k", { metaKey: true });
    document.removeEventListener("keydown", listener);
    expect(reached).toBe(2);
  });

  test("the field is a combobox over a listbox, with a hint and a status line", async () => {
    const picker = await mountPicker();
    const field = picker.field();
    expect(field.getAttribute("role")).toBe("combobox");
    expect(field.getAttribute("aria-expanded")).toBe("true");
    const active = document.getElementById(field.getAttribute("aria-activedescendant")!);
    expect(active?.querySelector(".ve-picker-name")?.textContent).toBe("Documents");
    expect(document.getElementById(field.getAttribute("aria-controls")!)?.getAttribute("role")).toBe("listbox");
    expect(document.getElementById(field.getAttribute("aria-describedby")!)?.textContent).toContain("~/");
    expect(picker.container.querySelector("output")?.textContent).toBe("~, 3 items");
  });

  test("a query starting with . lists hidden folders", async () => {
    const picker = await mountPicker();
    await type(picker.field(), ".");
    expect(picker.calls.at(-1)).toEqual({ path: HOME, mode: "folder", hidden: true });
    expect(picker.names()).toEqual([".config"]);
    await type(picker.field(), "");
    expect(picker.names()).toEqual(["Documents", "fun", "zeta"]);
  });

  test("the breadcrumb navigates; Choose This Folder picks the shown folder", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun/scratch` });
    expect(picker.crumbs()).toEqual(["~", "fun", "scratch"]);
    await click([...picker.container.querySelectorAll(".ve-crumb")][1]);
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    expect(picker.highlighted()).toBe("scratch");
    const choose = [...picker.container.querySelectorAll<HTMLButtonElement>(".ve-button")].find(
      (button) => button.textContent === "Choose This Folder",
    )!;
    await click(choose);
    expect(picker.chosen).toEqual([`${HOME}/fun`]);
  });

  test("Enter in an empty folder chooses it", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun/scratch` });
    await press(picker.field(), "Enter");
    expect(picker.chosen).toEqual([`${HOME}/fun/scratch`]);
  });

  test("file mode lists markdown files; Enter enters a folder and chooses a file", async () => {
    const picker = await mountPicker({ mode: "file" });
    expect(picker.names()).toEqual(["Documents", "fun", "zeta", "notes.md"]);
    await press(picker.field(), "Enter"); // Documents
    expect(picker.crumbs()).toEqual(["~", "Documents"]);
    expect(picker.chosen).toEqual([]);
    await press(picker.field(), "Enter");
    expect(picker.chosen).toEqual([`${HOME}/Documents/plan.md`]);
    expect(picker.container.querySelector(".ve-button-primary")).toBeNull();
  });

  test("Escape clears the query, then cancels", async () => {
    const picker = await mountPicker();
    await type(picker.field(), "zz");
    expect(picker.container.querySelector(".ve-picker-empty")?.textContent).toBe("No matches");
    await press(picker.field(), "Escape");
    expect(picker.field().value).toBe("");
    expect(picker.cancelled()).toBe(0);
    await press(picker.field(), "Escape");
    expect(picker.cancelled()).toBe(1);
  });

  test("a refused folder shows the failure and keeps the field", async () => {
    const picker = await mountPicker({ start: "/nowhere" });
    expect(picker.container.querySelector(".ve-picker-empty")?.textContent).toBe("Could not list this folder.");
    await type(picker.field(), "~/");
    expect(picker.names()).toEqual(["Documents", "fun", "zeta"]);
  });

  test("a mouse press highlights a row; a double click enters it", async () => {
    const picker = await mountPicker();
    const zeta = picker.levelRows()[2];
    await mouseDown(zeta);
    expect(picker.highlighted()).toBe("zeta");
    const fun = picker.levelRows()[1];
    await doubleClick(fun);
    expect(picker.crumbs()).toEqual(["~", "fun"]);
  });
});
