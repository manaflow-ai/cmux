// The pure pieces of the viewer empty states: the host op answers, the fuzzy ranking, the picker
// key map and breadcrumb, drop parsing and relative times.
import { describe, expect, test } from "bun:test";
import { droppedItem } from "../src/viewer-empty/drop";
import { fuzzyFilter, fuzzyScore } from "../src/viewer-empty/fuzzy";
import {
  diffConfigNeedsPick,
  markdownConfigNeedsPick,
  parseChosenPath,
  parseRecents,
  tildePath,
} from "../src/viewer-empty/ops";
import {
  breadcrumb,
  folderQuery,
  isPathQuery,
  parentPath,
  pathQuery,
  pickerKeyAction,
  completedQuery,
  parsePickerPlaces,
  pathCompletions,
  pickerRows,
  standardPlaces,
} from "../src/viewer-empty/pickerModel";
import { relativeTime } from "../src/viewer-empty/time";
import { emptySourceOptions } from "../src/viewer-empty/DiffEmptyState";
import pickerStrings from "../src/viewer-empty/generated/strings.json";

describe("host op answers", () => {
  test("recents keep valid rows, newest first", () => {
    expect(
      parseRecents({
        items: [
          { path: "/a", openedAt: 1 },
          { path: "", openedAt: 5 },
          { path: "/b", openedAt: 3, source: "staged" },
          { openedAt: 9 },
          { path: "/c", openedAt: Number.NaN },
        ],
      }),
    ).toEqual([
      { path: "/b", openedAt: 3, source: "staged" },
      { path: "/a", openedAt: 1 },
    ]);
    expect(parseRecents(null)).toEqual([]);
  });

  test("choose answers a path or null", () => {
    expect(parseChosenPath({ path: "/x" })).toBe("/x");
    expect(parseChosenPath(null)).toBeNull();
    expect(parseChosenPath({ path: "" })).toBeNull();
  });

  test("the empty state shows for a pick config or one without a repository or file", () => {
    expect(diffConfigNeedsPick({ pick: true, payload: { repoRoot: "/r" } })).toBe(true);
    expect(diffConfigNeedsPick({ payload: { transport: {} } })).toBe(true);
    expect(diffConfigNeedsPick({ payload: { repoRoot: "/r" } })).toBe(false);
    expect(diffConfigNeedsPick({ payload: { sessionSource: { kind: "patch", path: "/p" } } })).toBe(false);
    expect(markdownConfigNeedsPick({ pick: true })).toBe(true);
    expect(markdownConfigNeedsPick({ text: "" })).toBe(true);
    expect(markdownConfigNeedsPick({ path: "/a.md", text: "", hash: "h" })).toBe(false);
  });

  test("paths under home read with ~", () => {
    expect(tildePath("/Users/me/fun", "/Users/me")).toBe("~/fun");
    expect(tildePath("/Users/me", "/Users/me/")).toBe("~");
    expect(tildePath("/Users/meme", "/Users/me")).toBe("/Users/meme");
    expect(tildePath("/tmp", null)).toBe("/tmp");
  });
});

describe("source choices", () => {
  test("come from the source menu model in the empty state's order", () => {
    expect(emptySourceOptions("/r").map((option) => [option.kind, option.source])).toEqual([
      ["branch", { kind: "branch", repoRoot: "/r" }],
      ["uncommitted", { kind: "branch", repoRoot: "/r", baseRef: "HEAD" }],
      ["staged", { kind: "staged", repoRoot: "/r" }],
      ["unstaged", { kind: "unstaged", repoRoot: "/r" }],
    ]);
  });
});

describe("fuzzy filter", () => {
  test("prefix beats word starts beats scattered letters; misses drop", () => {
    expect(fuzzyScore("x", "abc")).toBeNull();
    const names = ["scratch", "cmuxterm-hq", "chatmux", "cmux-next-diff"];
    expect(fuzzyFilter(names, "cm", (name) => name)).toEqual(["cmuxterm-hq", "cmux-next-diff", "chatmux"]);
    expect(fuzzyFilter(names, "cnd", (name) => name)).toEqual(["cmux-next-diff"]);
    expect(fuzzyFilter(names, "", (name) => name)).toEqual(names);
  });

  test("ties keep the input order", () => {
    expect(fuzzyFilter(["b-x", "a-x"], "x", (name) => name)).toEqual(["b-x", "a-x"]);
  });
});

describe("picker model", () => {
  const entries = [
    { name: "zeta", path: "/h/zeta", kind: "dir" as const },
    { name: "Alpha", path: "/h/Alpha", kind: "dir" as const, git: true },
    { name: "a.md", path: "/h/a.md", kind: "file" as const },
    { name: "b.txt", path: "/h/b.txt", kind: "file" as const },
    { name: ".hidden", path: "/h/.hidden", kind: "dir" as const },
  ];

  test("rows: recent first, folders before files, markdown only in file mode, hidden only for .", () => {
    const recent = new Set(["/h/zeta"]);
    expect(pickerRows(entries, "", "folder", recent).map((row) => row.name)).toEqual(["zeta", "Alpha"]);
    expect(pickerRows(entries, "", "file", new Set()).map((row) => row.name)).toEqual(["Alpha", "zeta", "a.md"]);
    expect(pickerRows(entries, ".h", "folder", new Set()).map((row) => row.name)).toEqual([".hidden"]);
  });

  test("keys", () => {
    const at = (query: string, caret = query.length) => ({ query, caretStart: caret, caretEnd: caret });
    expect(pickerKeyAction({ key: "Tab" }, at(""))).toEqual({ kind: "enter" });
    expect(pickerKeyAction({ key: "Tab", shiftKey: true }, at(""))).toBeNull();
    expect(pickerKeyAction({ key: "ArrowRight" }, at("ab"))).toEqual({ kind: "enter" });
    expect(pickerKeyAction({ key: "ArrowRight" }, at("ab", 1))).toBeNull();
    expect(pickerKeyAction({ key: "ArrowLeft" }, at("ab", 0))).toEqual({ kind: "up" });
    expect(pickerKeyAction({ key: "ArrowLeft" }, at("ab", 1))).toBeNull();
    expect(pickerKeyAction({ key: "Backspace" }, at(""))).toEqual({ kind: "up" });
    expect(pickerKeyAction({ key: "Backspace" }, at("a"))).toBeNull();
    expect(pickerKeyAction({ key: "Enter" }, at("a"))).toEqual({ kind: "choose" });
    expect(pickerKeyAction({ key: "Escape" }, at("a"))).toEqual({ kind: "clear" });
    expect(pickerKeyAction({ key: "Escape" }, at(""))).toEqual({ kind: "cancel" });
    expect(pickerKeyAction({ key: "n", ctrlKey: true }, at(""))).toEqual({ kind: "move", delta: 1 });
    expect(pickerKeyAction({ key: "ArrowDown", metaKey: true }, at(""))).toBeNull();
    // Cmd-Up is the parent folder; other Cmd and Ctrl chords are the app's.
    expect(pickerKeyAction({ key: "ArrowUp", metaKey: true }, at("ab", 1))).toEqual({ kind: "up" });
    expect(pickerKeyAction({ key: "ArrowUp", metaKey: true, shiftKey: true }, at(""))).toBeNull();
    expect(pickerKeyAction({ key: "s", metaKey: true }, at(""))).toBeNull();
    expect(pickerKeyAction({ key: "PageDown", ctrlKey: true }, at(""))).toBeNull();
    expect(pickerKeyAction({ key: "Enter", ctrlKey: true }, at(""))).toBeNull();
    // Right to left: the inline-end arrow (Left) enters, the inline-start arrow (Right) goes up.
    const rtl = (query: string, caret = query.length) => ({ ...at(query, caret), dir: "rtl" as const });
    expect(pickerKeyAction({ key: "ArrowLeft" }, rtl("ab"))).toEqual({ kind: "enter" });
    expect(pickerKeyAction({ key: "ArrowRight" }, rtl("ab", 0))).toEqual({ kind: "up" });
    expect(pickerKeyAction({ key: "ArrowRight" }, rtl("ab"))).toBeNull();
  });

  test("ranking: prefix matches first in Finder order (c2 before c10), then fuzzy by score", () => {
    const level = ["c10", "abc", "c2", "Cx", "xc"].map((name) => ({ name, path: `/h/${name}`, kind: "dir" as const }));
    const ranked = pickerRows(level, "c", "folder", new Set()).map((row) => row.name);
    expect(ranked.slice(0, 3)).toEqual(["c2", "c10", "Cx"]);
    expect(ranked.slice(3).sort()).toEqual(["abc", "xc"]);
  });

  test("path mode: / and ~/ queries name a folder and the segment being typed", () => {
    expect(isPathQuery("~")).toBe(false);
    expect(isPathQuery("~fun")).toBe(false);
    expect(isPathQuery("~/")).toBe(true);
    expect(pathQuery("fun", "/h")).toBeNull();
    expect(pathQuery("/", "/h")).toEqual({ typed: "/", dir: "/", rest: "" });
    expect(pathQuery("/Us", "/h")).toEqual({ typed: "/", dir: "/", rest: "Us" });
    expect(pathQuery("/tmp/a", "/h")).toEqual({ typed: "/tmp/", dir: "/tmp", rest: "a" });
    expect(pathQuery("~/", "/h/")).toEqual({ typed: "~/", dir: "/h", rest: "" });
    expect(pathQuery("~/fun/cm", "/h")).toEqual({ typed: "~/fun/", dir: "/h/fun", rest: "cm" });
    expect(pathQuery("~/fun/", null)).toEqual({ typed: "~/fun/", dir: "~/fun", rest: "" });
    expect(folderQuery("/h/fun", "/h")).toBe("~/fun/");
    expect(folderQuery("/h", "/h")).toBe("~/");
    expect(folderQuery("/tmp", "/h")).toBe("/tmp/");
    expect(folderQuery("/", "/h")).toBe("/");
  });

  test("path mode completes the segment: case-insensitive prefix, dot entries only after a dot", () => {
    const entries = [
      { name: "Code", path: "/h/Code", kind: "dir" as const },
      { name: "cmux", path: "/h/cmux", kind: "dir" as const },
      { name: ".config", path: "/h/.config", kind: "dir" as const },
      { name: "notes.md", path: "/h/notes.md", kind: "file" as const },
    ];
    // The picker lists the level unfiltered, or with hidden entries for a segment starting ".".
    const level = pickerRows(entries, "", "file", new Set());
    const hidden = pickerRows(entries, ".", "file", new Set());
    expect(pathCompletions(level, "c").map((row) => row.name)).toEqual(["cmux", "Code"]);
    expect(pathCompletions(level, "").map((row) => row.name)).toEqual(["cmux", "Code", "notes.md"]);
    expect(pathCompletions(level, ".c").map((row) => row.name)).toEqual([]);
    expect(pathCompletions(hidden, ".c").map((row) => row.name)).toEqual([".config"]);
    // In Finder order the prefix test keeps the level's order (folders first).
    const path = pathQuery("~/c", "/h")!;
    expect(
      completedQuery(
        path,
        level.find((row) => row.name === "cmux")!,
      ),
    ).toBe("~/cmux/");
    expect(
      completedQuery(
        path,
        level.find((row) => row.name === "notes.md")!,
      ),
    ).toBe("~/notes.md");
  });

  test("Locations come from the host op, in its order, each folder once", () => {
    expect(
      parsePickerPlaces({
        locations: [
          { kind: "workspace", path: "/h/fun/cmux/" },
          { kind: "home", path: "/h" },
          { kind: "desktop", path: "/h/Desktop" },
          { kind: "pinned", path: "/h" },
          { kind: "nonsense", path: "/x" },
          { kind: "pinned", path: "" },
          null,
          { kind: "iCloudDrive", path: "/h/Library/Mobile Documents/com~apple~CloudDocs" },
        ],
      }),
    ).toEqual([
      { kind: "workspace", path: "/h/fun/cmux" },
      { kind: "home", path: "/h" },
      { kind: "desktop", path: "/h/Desktop" },
      { kind: "iCloudDrive", path: "/h/Library/Mobile Documents/com~apple~CloudDocs" },
    ]);
    expect(parsePickerPlaces(null)).toEqual([]);
    expect(standardPlaces("/h/").map((place) => place.kind)).toEqual(["home", "desktop", "documents", "downloads"]);
  });

  test("breadcrumb and parent", () => {
    expect(breadcrumb("/Users/me/fun/x", "/Users/me")).toEqual([
      { label: "~", path: "/Users/me" },
      { label: "fun", path: "/Users/me/fun" },
      { label: "x", path: "/Users/me/fun/x" },
    ]);
    expect(breadcrumb("/tmp/a", "/Users/me")).toEqual([
      { label: "/", path: "/" },
      { label: "tmp", path: "/tmp" },
      { label: "a", path: "/tmp/a" },
    ]);
    expect(parentPath("/a/b")).toBe("/a");
    expect(parentPath("/a")).toBe("/");
    expect(parentPath("/")).toBeNull();
  });
});

describe("drops", () => {
  const transfer = (data: Record<string, string>, files: Array<{ name: string; path?: string }> = []) => ({
    types: [...Object.keys(data), ...(files.length ? ["Files"] : [])],
    getData: (type: string) => data[type] ?? "",
    files,
  });

  test("file URLs and absolute text paths carry a path", () => {
    expect(droppedItem(transfer({ "text/uri-list": "# c\nfile:///Users/me/a%20b/\n" }))).toEqual({
      path: "/Users/me/a b",
      name: "a b",
    });
    expect(droppedItem(transfer({ "text/plain": "/Users/me/x.md" }))).toEqual({ path: "/Users/me/x.md", name: "x.md" });
    expect(droppedItem(transfer({ "text/uri-list": "https://example.com/x" }))).toBeNull();
  });

  test("a Finder file without a path keeps its name only", () => {
    expect(droppedItem(transfer({}, [{ name: "notes.md" }]))).toEqual({ path: null, name: "notes.md" });
    expect(droppedItem(transfer({}, [{ name: "n.md", path: "/x/n.md" }]))).toEqual({ path: "/x/n.md", name: "n.md" });
  });
});

describe("relative time", () => {
  const now = Date.UTC(2026, 9, 4, 12);
  test("rounds to the largest unit, in the page language", () => {
    expect(relativeTime(now - 20_000, now, "en")).toBe("now");
    expect(relativeTime(now - 5 * 60_000, now, "en")).toBe("5 min. ago");
    expect(relativeTime(now - 26 * 3600_000, now, "en")).toBe("yesterday");
    expect(relativeTime(now - 3 * 86400_000, now, "ja")).toBe("3 日前");
  });
});

describe("picker copy", () => {
  // PICKER-PATHS: `~` alone is text, not a jump key; only `/` and `~/` start a path. The field's
  // placeholder and hint must not teach the old `~` jump in any language.
  test("the placeholder and hint never offer ~ as a jump key, in every locale", () => {
    const table = pickerStrings as Record<string, Record<string, string>>;
    const offenders = Object.entries(table).flatMap(([locale, strings]) =>
      ["picker.placeholder", "picker.hintPath"]
        .filter((key) => /~(?!\/)/.test(strings[key] ?? ""))
        .map((key) => `${locale} ${key}: ${strings[key]}`),
    );
    expect(Object.keys(table)).toHaveLength(21);
    expect(offenders).toEqual([]);
    expect(table.en["picker.placeholder"]).toBe("Type to filter, or start with / to type a path");
  });
});
