import { describe, expect, test } from "bun:test";
import {
  breadcrumb,
  completedQuery,
  folderQuery,
  parentPath,
  parsePickerPlaces,
  pathCompletions,
  pathQuery,
  pickerKeyAction,
  pickerRows,
  recentPathSet,
  standardPlaces,
} from "../src/viewer-empty/pickerModel";
import type { PickerEntry } from "../src/viewer-empty/ops";

const HOME = "/Users/me";
const entry = (name: string, kind: PickerEntry["kind"], extra: Partial<PickerEntry> = {}): PickerEntry => ({
  name,
  path: `${HOME}/${name}`,
  kind,
  ...extra,
});

describe("path picker model", () => {
  test("sorts recent folders first, keeps directories ahead of files, and filters by mode", () => {
    const rows = pickerRows(
      [
        entry("zeta.md", "file"),
        entry("alpha", "dir"),
        entry("repo", "dir", { git: true }),
        entry("README.md", "file"),
        entry(".config", "dir"),
      ],
      "",
      "file",
      recentPathSet([`${HOME}/zeta.md`], "file"),
    );
    expect(rows.map((row) => row.name)).toEqual(["zeta.md", "alpha", "repo", "README.md"]);
    expect(rows.find((row) => row.name === "zeta.md")?.recent).toBe(true);
    expect(
      pickerRows([entry("alpha", "dir"), entry("zeta.txt", "file")], "", "anyFile", new Set()).map((row) => row.name),
    ).toEqual(["alpha", "zeta.txt"]);
    expect(pickerRows([entry(".config", "dir")], ".", "folder", new Set()).map((row) => row.name)).toEqual([".config"]);
  });

  test("splits and completes absolute and home-relative path queries", () => {
    expect(pathQuery("~/Projects/cm", HOME)).toEqual({ typed: "~/Projects/", dir: `${HOME}/Projects`, rest: "cm" });
    expect(pathQuery("/Users/me/", HOME)).toEqual({ typed: "/Users/me/", dir: HOME, rest: "" });
    const rows = [entry("cmux", "dir"), entry("cmux.md", "file"), entry(".config", "dir")].map((row) => ({
      ...row,
      recent: false,
    }));
    expect(pathCompletions(rows, "cm").map((row) => row.name)).toEqual(["cmux", "cmux.md"]);
    expect(completedQuery({ typed: "~/Projects/", dir: `${HOME}/Projects`, rest: "cm" }, rows[0])).toBe(
      "~/Projects/cmux/",
    );
    expect(folderQuery(`${HOME}/Projects`, HOME)).toBe("~/Projects/");
  });

  test("folder and markdown modes exclude files that cannot be chosen", () => {
    const entries = [entry("notes", "dir"), entry("README.md", "file"), entry("preview.png", "file")];
    expect(pickerRows(entries, "", "folder", new Set()).map((row) => row.name)).toEqual(["notes"]);
    expect(pickerRows(entries, "", "file", new Set()).map((row) => row.name)).toEqual(["notes", "README.md"]);
    expect(pickerRows(entries, "preview", "file", new Set())).toEqual([]);
    expect(pickerRows(entries, "preview", "anyFile", new Set()).map((row) => row.name)).toEqual(["preview.png"]);
  });

  test("recent files promote their parent folder without promoting unrelated folders", () => {
    const recentFile = `${HOME}/notes/draft.md`;
    expect([...recentPathSet([recentFile], "file")]).toEqual([recentFile, `${HOME}/notes`]);
    expect([...recentPathSet([`${HOME}/notes`], "folder")]).toEqual([`${HOME}/notes`]);
    const rows = pickerRows(
      [entry("archive", "dir"), entry("notes", "dir")],
      "",
      "file",
      recentPathSet([recentFile], "file"),
    );
    expect(rows.map((row) => [row.name, row.recent])).toEqual([
      ["notes", true],
      ["archive", false],
    ]);
  });

  test("path completion hides dot entries until requested and leaves files without a trailing slash", () => {
    const rows = [entry(".config", "dir"), entry("README.md", "file")].map((row) => ({ ...row, recent: false }));
    expect(pathCompletions(rows, "").map((row) => row.name)).toEqual(["README.md"]);
    expect(pathCompletions(rows, ".c").map((row) => row.name)).toEqual([".config"]);
    expect(pathCompletions(rows, "read").map((row) => row.name)).toEqual(["README.md"]);
    expect(completedQuery({ typed: "~/", dir: HOME, rest: "read" }, rows[1])).toBe("~/README.md");
    expect(pathQuery("~/", null)).toEqual({ typed: "~/", dir: "~", rest: "" });
    expect(pathQuery("/", HOME)).toEqual({ typed: "/", dir: "/", rest: "" });
  });

  test("keeps parent and breadcrumb transitions rooted", () => {
    expect(parentPath("/")).toBeNull();
    expect(parentPath(`${HOME}/Projects/cmux`)).toBe(`${HOME}/Projects`);
    expect(breadcrumb(`${HOME}/Projects/cmux`, HOME)).toEqual([
      { label: "~", path: HOME },
      { label: "Projects", path: `${HOME}/Projects` },
      { label: "cmux", path: `${HOME}/Projects/cmux` },
    ]);
    expect(breadcrumb("/tmp", HOME)).toEqual([
      { label: "/", path: "/" },
      { label: "tmp", path: "/tmp" },
    ]);
    expect(parentPath(`${HOME}/Projects/`)).toBe(HOME);
    expect(folderQuery("/", HOME)).toBe("/");
    expect(folderQuery(`${HOME}-other`, HOME)).toBe(`${HOME}-other/`);
    expect(breadcrumb(`${HOME}-other`, HOME)).toEqual([
      { label: "/", path: "/" },
      { label: "Users", path: "/Users" },
      { label: "me-other", path: `${HOME}-other` },
    ]);
  });

  test("parses host locations defensively and provides standard fallbacks", () => {
    expect(
      parsePickerPlaces({
        locations: [
          { kind: "workspace", path: `${HOME}/Projects/` },
          { kind: "workspace", path: `${HOME}/Projects` },
          { kind: "unknown", path: "/tmp" },
          null,
        ],
      }),
    ).toEqual([{ kind: "workspace", path: `${HOME}/Projects` }]);
    expect(standardPlaces(HOME).map((place) => place.path)).toEqual([
      HOME,
      `${HOME}/Desktop`,
      `${HOME}/Documents`,
      `${HOME}/Downloads`,
    ]);
  });
});

describe("path picker key model", () => {
  const state = { query: "", caretStart: 0, caretEnd: 0, dir: "ltr" as const };

  test("maps navigation, completion, choosing, and cancellation", () => {
    expect(pickerKeyAction({ key: "ArrowDown" }, state)).toEqual({ kind: "move", delta: 1 });
    expect(pickerKeyAction({ key: "ArrowUp", metaKey: true }, state)).toEqual({ kind: "up" });
    expect(pickerKeyAction({ key: "Tab" }, state)).toEqual({ kind: "enter" });
    expect(pickerKeyAction({ key: "Enter" }, state)).toEqual({ kind: "choose" });
    expect(pickerKeyAction({ key: "Escape" }, state)).toEqual({ kind: "cancel" });
    expect(pickerKeyAction({ key: "Escape" }, { ...state, query: "cm" })).toEqual({ kind: "clear" });
  });

  test("keeps arrows as text editing until the caret reaches the inline edge", () => {
    expect(pickerKeyAction({ key: "ArrowRight" }, { query: "cm", caretStart: 1, caretEnd: 1 })).toBeNull();
    expect(pickerKeyAction({ key: "ArrowRight" }, { query: "cm", caretStart: 2, caretEnd: 2 })).toEqual({
      kind: "enter",
    });
    expect(pickerKeyAction({ key: "ArrowLeft" }, { ...state, query: "cm", caretStart: 0, caretEnd: 0 })).toEqual({
      kind: "up",
    });
    expect(
      pickerKeyAction({ key: "ArrowLeft" }, { ...state, query: "cm", caretStart: 2, caretEnd: 2, dir: "rtl" }),
    ).toEqual({ kind: "enter" });
    expect(
      pickerKeyAction({ key: "ArrowRight" }, { ...state, query: "cm", caretStart: 0, caretEnd: 0, dir: "rtl" }),
    ).toEqual({ kind: "up" });
  });

  test("selection and modified text editing never enter or leave a folder", () => {
    for (const dir of ["ltr", "rtl"] as const) {
      const selected = { query: "cmux", caretStart: 0, caretEnd: 4, dir };
      for (const key of ["ArrowLeft", "ArrowRight"]) {
        expect(pickerKeyAction({ key }, selected)).toBeNull();
        expect(pickerKeyAction({ key, shiftKey: true }, { ...selected, caretStart: 4 })).toBeNull();
        expect(pickerKeyAction({ key, altKey: true }, state)).toBeNull();
        expect(pickerKeyAction({ key, metaKey: true }, state)).toBeNull();
      }
    }
    expect(pickerKeyAction({ key: "Tab", shiftKey: true }, state)).toBeNull();
    expect(pickerKeyAction({ key: "Backspace" }, { ...state, query: "cmux", caretStart: 4, caretEnd: 4 })).toBeNull();
  });

  test("modified arrows, Return and Escape stay with text editing or the app", () => {
    // The only widget-specific modifier chords are Cmd-Up and Ctrl-N/P.
    for (const key of ["ArrowUp", "ArrowDown", "Enter", "Escape", "PageUp", "PageDown", "Backspace"]) {
      expect(pickerKeyAction({ key, ctrlKey: true }, state)).toBeNull();
      expect(pickerKeyAction({ key, shiftKey: true }, state)).toBeNull();
    }
    expect(pickerKeyAction({ key: "ArrowUp", metaKey: true }, state)).toEqual({ kind: "up" });
    expect(pickerKeyAction({ key: "n", ctrlKey: true }, state)).toEqual({ kind: "move", delta: 1 });
    expect(pickerKeyAction({ key: "p", ctrlKey: true }, state)).toEqual({ kind: "move", delta: -1 });
    expect(pickerKeyAction({ key: "n", ctrlKey: true, shiftKey: true }, state)).toBeNull();
  });

  test("large listings support paging and edges without stealing query Home and End", () => {
    expect(pickerKeyAction({ key: "PageDown" }, state)).toEqual({ kind: "move", delta: 10 });
    expect(pickerKeyAction({ key: "PageUp" }, state)).toEqual({ kind: "move", delta: -10 });
    expect(pickerKeyAction({ key: "Home" }, state)).toEqual({ kind: "edge", to: "first" });
    expect(pickerKeyAction({ key: "End" }, state)).toEqual({ kind: "edge", to: "last" });
    expect(pickerKeyAction({ key: "Home" }, { ...state, query: "cmux" })).toBeNull();
    expect(pickerKeyAction({ key: "End" }, { ...state, query: "cmux" })).toBeNull();
  });
});
