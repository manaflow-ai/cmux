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
import { act } from "react";
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

async function mountPicker(
  options: { mode?: PickerMode; recents?: string[]; start?: string | null; locations?: () => Promise<unknown> } = {},
) {
  const chosen: string[] = [];
  let cancelled = 0;
  const { list, calls } = fakeList();
  const container = await render(
    <PathPicker
      mode={options.mode ?? "folder"}
      list={list}
      strings={strings}
      recents={options.recents}
      locations={options.locations}
      start={options.start ?? null}
      onChoose={(path) => chosen.push(path)}
      onCancel={() => (cancelled += 1)}
    />,
  );
  const field = () => container.querySelector<HTMLInputElement>(".ve-picker-field")!;
  // The entries of the level (not Locations, Recent or the path mode's "Go to" row).
  const names = () =>
    [...container.querySelectorAll('.ve-picker-row[data-row="entry"] .ve-picker-name')].map((node) => node.textContent);
  const goRow = () => container.querySelector('.ve-picker-row[data-row="go"]')?.textContent ?? null;
  const highlighted = () =>
    container.querySelector('.ve-picker-row[aria-selected="true"] .ve-picker-name')?.textContent;
  const crumbs = () => [...container.querySelectorAll(".ve-crumb")].map((node) => node.textContent);
  // The rows of the level (not the Locations section above it).
  const levelRows = () => [...container.querySelectorAll<HTMLElement>('.ve-picker-row[data-row="entry"]')];
  const locations = () => [...container.querySelectorAll(".ve-picker-location")].map((node) => node.textContent);
  return {
    container,
    field,
    names,
    goRow,
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

  test("no jump keys: ~ alone and name/ are filter text", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await type(picker.field(), "~");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    expect(picker.container.querySelector(".ve-picker-empty")?.textContent).toBe("No matches");
    await type(picker.field(), "scratch/");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    expect(picker.names()).toEqual([]);
  });

  test("path mode lists the typed folder's completions; Tab completes, Return goes there", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await type(picker.field(), "/");
    expect(picker.crumbs()).toEqual(["/"]);
    // An empty segment: "Go to" the typed folder first, then its entries.
    expect(picker.goRow()).toBe("Go to /");
    // Path mode writes folders as they complete, with their "/".
    expect(picker.names()).toEqual(["tmp/", "Users/"]);
    expect(picker.field().value).toBe("/");
    await type(picker.field(), "/u");
    expect(picker.goRow()).toBeNull();
    expect(picker.names()).toEqual(["Users/"]);
    // Tab completes the segment; a folder ends with "/" and its entries follow.
    await press(picker.field(), "Tab");
    expect(picker.field().value).toBe("/Users/");
    expect(picker.crumbs()).toEqual(["/", "Users"]);
    expect(picker.names()).toEqual(["me/"]);
    await type(picker.field(), "/Users/x");
    expect(picker.container.querySelector(".ve-picker-empty")?.textContent).toBe("Nothing in /Users/ starts with that");
    // Return on a completed folder goes there and leaves path mode.
    await type(picker.field(), "~/fu");
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.names()).toEqual(["fun/"]);
    await press(picker.field(), "Enter");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    expect(picker.field().value).toBe("");
    expect(picker.chosen).toEqual([]);
    // Return on "Go to" goes to the typed folder.
    await type(picker.field(), "/tmp/");
    expect(picker.highlighted()).toBe("Go to /tmp/");
    await press(picker.field(), "Enter");
    expect(picker.crumbs()).toEqual(["/", "tmp"]);
    expect(picker.field().value).toBe("");
  });

  test("path mode: losing the prefix filters the folder it started from; Escape clears, then closes", async () => {
    const picker = await mountPicker({ start: `${HOME}/fun` });
    await type(picker.field(), "/U");
    expect(picker.crumbs()).toEqual(["/"]);
    await type(picker.field(), "U");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    await type(picker.field(), "~/D");
    expect(picker.names()).toEqual(["Documents/"]);
    // Cmd-Up goes to the parent and keeps path mode.
    await press(picker.field(), "ArrowUp", { metaKey: true });
    expect(picker.crumbs()).toEqual(["/", "Users"]);
    expect(picker.field().value).toBe("/Users/");
    await press(picker.field(), "Escape");
    expect(picker.field().value).toBe("");
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    expect(picker.cancelled()).toBe(0);
    await press(picker.field(), "Escape");
    expect(picker.cancelled()).toBe(1);
  });

  test("path mode in file mode: Tab completes a file's name, Return chooses it", async () => {
    const picker = await mountPicker({ mode: "file" });
    await type(picker.field(), "~/no");
    expect(picker.names()).toEqual(["notes.md"]);
    await press(picker.field(), "Tab");
    expect(picker.field().value).toBe("~/notes.md");
    await press(picker.field(), "Enter");
    expect(picker.chosen).toEqual([`${HOME}/notes.md`]);
  });

  test("Locations at the start folder: Recent, then the host's places, in its order", async () => {
    const asked: number[] = [];
    const picker = await mountPicker({
      start: `${HOME}/fun`,
      recents: [`${HOME}/fun/scratch`, "/tmp"],
      locations: async () => {
        asked.push(1);
        return {
          locations: [
            { kind: "workspace", path: `${HOME}/fun/cmuxterm-hq` },
            { kind: "home", path: HOME },
            { kind: "desktop", path: `${HOME}/Desktop` },
            { kind: "documents", path: `${HOME}/Documents` },
            { kind: "downloads", path: `${HOME}/Downloads` },
            { kind: "iCloudDrive", path: `${HOME}/Library/Mobile Documents/com~apple~CloudDocs` },
            { kind: "pinned", path: "/tmp" },
          ],
        };
      },
    });
    expect(asked).toEqual([1]);
    expect(picker.locations()).toEqual([
      "Recently opened",
      "cmuxterm-hq",
      "Home",
      "Desktop",
      "Documents",
      "Downloads",
      "iCloud Drive",
      "tmp",
    ]);
    expect(picker.container.querySelector(".ve-picker-section")?.textContent).toBe("Locations");
    // The level's first row is highlighted; typing hides the Locations.
    expect(picker.highlighted()).toBe("scratch");
    await type(picker.field(), "s");
    expect(picker.locations()).toEqual([]);
    await type(picker.field(), "");
    // Recent is a page of the recent items; Return on a folder there chooses it (folder mode).
    for (let index = 0; index < 8; index += 1) await press(picker.field(), "ArrowUp");
    await press(picker.field(), "Enter");
    expect(picker.crumbs()).toEqual(["~", "fun", "Recently opened"]);
    expect([...picker.container.querySelectorAll(".ve-picker-name")].map((node) => node.textContent)).toEqual([
      "scratch",
      "tmp",
    ]);
    await press(picker.field(), "ArrowUp", { metaKey: true });
    expect(picker.crumbs()).toEqual(["~", "fun"]);
    // A place opens its folder; Locations show only at the start folder.
    await press(picker.field(), "Home");
    await press(picker.field(), "ArrowDown");
    await press(picker.field(), "ArrowDown"); // Home
    await press(picker.field(), "Enter");
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.locations()).toEqual([]);
  });

  test("without a locations op, Locations are Home and its standard folders", async () => {
    const picker = await mountPicker();
    expect(picker.locations()).toEqual(["Home", "Desktop", "Documents", "Downloads"]);
    expect(picker.highlighted()).toBe("Documents");
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
    expect(document.getElementById(field.getAttribute("aria-describedby")!)?.textContent).toBe(
      "Type to filter, or start with / to type a path",
    );
    expect(picker.container.querySelector("output")?.textContent).toBe("~, 3 items");
  });

  test("a query starting with . lists hidden folders", async () => {
    const picker = await mountPicker();
    await type(picker.field(), ".");
    // The level is listed again with hidden entries (later calls prefetch the next levels).
    expect(picker.calls).toContainEqual({ path: HOME, mode: "folder", hidden: true });
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

  test("zero latency: Tab into a prefetched folder and Backspace back show the level at once", async () => {
    const picker = await mountPicker();
    // The highlighted folder and the parent were prefetched when the level appeared.
    expect(picker.calls).toContainEqual({ path: `${HOME}/Documents`, mode: "folder", hidden: false });
    const before = picker.calls.length;
    picker.field().focus();
    // No await between the key and the check: the level must be there in the key's own frame.
    act(() => {
      picker.field().dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
    });
    expect(picker.crumbs()).toEqual(["~", "Documents"]);
    expect(picker.calls.length).toBeGreaterThanOrEqual(before);
    // Showing Documents prefetched its parent; let that answer, then go up with no await again.
    await new Promise((resolve) => setTimeout(resolve, 0));
    act(() => {
      picker.field().dispatchEvent(new KeyboardEvent("keydown", { key: "Backspace", bubbles: true }));
    });
    expect(picker.crumbs()).toEqual(["~"]);
    expect(picker.names()).toEqual(["Documents", "fun", "zeta"]);
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
    expect(picker.names()).toEqual(["Documents/", "fun/", "zeta/"]);
    expect(picker.goRow()).toBe("Go to ~/");
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
