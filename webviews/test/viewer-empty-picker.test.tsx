// The fallback path picker's interaction (PathPicker.tsx, the palette picker's reference): one
// level at a time, recent folders first, git repositories marked, fuzzy filter, Tab and Right
// enter, Left and Backspace go up, Enter chooses, ~ and / jump, the breadcrumb navigates.
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
  return { container, field, names, highlighted, crumbs, chosen, calls, cancelled: () => cancelled };
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
    const rows = [...picker.container.querySelectorAll<HTMLElement>(".ve-picker-row")];
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

  test("~ jumps home, / to the root, and name/ enters that folder", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await type(picker.field(), "/");
    expect(picker.crumbs()).toEqual(["/"]);
    expect(picker.names()).toEqual(["tmp", "Users"]);
    expect(picker.field().value).toBe("");
    await type(picker.field(), "~");
    expect(picker.crumbs()).toEqual(["~"]);
    await type(picker.field(), "fun/");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
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
    await type(picker.field(), "~");
    expect(picker.names()).toEqual(["Documents", "fun", "zeta"]);
  });

  test("a mouse press highlights a row; a double click enters it", async () => {
    const picker = await mountPicker();
    const zeta = [...picker.container.querySelectorAll(".ve-picker-row")][2];
    await mouseDown(zeta);
    expect(picker.highlighted()).toBe("zeta");
    const fun = [...picker.container.querySelectorAll(".ve-picker-row")][1];
    await doubleClick(fun);
    expect(picker.crumbs()).toEqual(["~", "fun"]);
  });
});
