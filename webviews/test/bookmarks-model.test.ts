// The Bookmarks page's pure rules, the Swift manager's: the tree over a listing, folder paths and
// choices, the typed URL, the drop rules, the delete dedupe and the ops one save or drop makes.
import { expect, test } from "bun:test";
import {
  buildTree,
  childrenOf,
  deleteOps,
  dropInto,
  dropOnRow,
  editorOps,
  editState,
  folderChoices,
  folderPath,
  moveOps,
  parseTypedURL,
  revealRoute,
  treeRows,
  urlCount,
} from "../src/pages/bookmarks/model";
import type { Bookmark } from "../src/pages/bookmarks/types";

const titles = { bar: "Bookmarks Bar", other: "Other Bookmarks" };

function node(id: string, parent: string, index: number, kind: Bookmark["kind"] = "url"): Bookmark {
  return {
    id,
    browser_profile_id: "default",
    parent,
    kind,
    index,
    title: id,
    ...(kind === "url" ? { url: `https://${id.toLowerCase()}.test/` } : {}),
    created_ms: 0,
  };
}

// bar: Work [Docs [Rust], PRs], GitHub, Reading []; other: Example
const listing = [
  node("Work", "bar", 0, "folder"),
  node("Docs", "Work", 0, "folder"),
  node("Rust", "Docs", 0),
  node("PRs", "Work", 1),
  node("GitHub", "bar", 1),
  node("Reading", "bar", 2, "folder"),
  node("Example", "other", 0),
];
const tree = buildTree([...listing].reverse());
const node$ = (id: string) => tree.nodes.get(id)!;
const ids = (rows: readonly Bookmark[]) => rows.map((row) => row.id);

test("a listing becomes a tree of ordered children", () => {
  expect(ids(childrenOf(tree, "bar"))).toEqual(["Work", "GitHub", "Reading"]);
  expect(ids(childrenOf(tree, "Work"))).toEqual(["Docs", "PRs"]);
  expect(ids(childrenOf(tree, "Reading"))).toEqual([]);
  expect(urlCount(tree, "Work")).toBe(1);
});

test("a node's folder path starts at its root", () => {
  expect(folderPath(tree, "Rust", titles).join(" › ")).toBe("Bookmarks Bar › Work › Docs");
  expect(folderPath(tree, "Example", titles)).toEqual(["Other Bookmarks"]);
});

test("folder choices list every folder under its root, without the edited folder's subtree", () => {
  const all = folderChoices(tree, titles).map((choice) => `${choice.depth}:${choice.id}`);
  expect(all).toEqual(["0:bar", "1:Work", "2:Docs", "1:Reading", "0:other"]);
  const forWork = folderChoices(tree, titles, "Work").map((choice) => choice.id);
  expect(forWork).toEqual(["bar", "Reading", "other"]);
  const collapsed = treeRows(tree, titles, new Set(["Work"])).map((row) => row.id);
  expect(collapsed).toEqual(["bar", "Work", "Reading", "other"]);
});

test("a typed URL gets a scheme the way the Swift editor gives one", () => {
  expect(parseTypedURL("example.com")).toBe("https://example.com");
  expect(parseTypedURL("  github.com/foo ")).toBe("https://github.com/foo");
  expect(parseTypedURL("localhost:3000")).toBe("http://localhost:3000");
  expect(parseTypedURL("localhost")).toBe("https://localhost");
  expect(parseTypedURL("http://example.com/a")).toBe("http://example.com/a");
  expect(parseTypedURL("about:blank")).toBe("about:blank");
  expect(parseTypedURL("not a url")).toBeNull();
  expect(parseTypedURL("nodot")).toBeNull();
  expect(parseTypedURL("")).toBeNull();
});

test("a drop on a folder row goes into it; on another row, before it", () => {
  expect(dropOnRow(tree, ["GitHub"], node$("Reading"))).toEqual({ parent: "Reading", index: 0 });
  expect(dropOnRow(tree, ["Reading"], node$("GitHub"))).toEqual({ parent: "bar", index: 1 });
  expect(dropOnRow(tree, ["Example"], node$("PRs"))).toEqual({ parent: "Work", index: 1 });
});

test("a drop never puts a node into itself or under itself", () => {
  expect(dropOnRow(tree, ["Work"], node$("Work"))).toBeNull();
  expect(dropInto(tree, ["Work"], "Docs")).toBeNull();
  // A dragged folder over its own descendant row: that row is inside it, so neither into nor before.
  expect(dropOnRow(tree, ["Work"], node$("PRs"))).toBeNull();
  expect(dropOnRow(tree, ["Work"], node$("Docs"))).toBeNull();
  expect(dropInto(tree, ["Docs"], "bar")).toEqual({ parent: "bar", index: 3 });
});

test("a multi-row drop is one block in tree order", () => {
  // Work and Reading before GitHub: [Work, Reading, GitHub].
  const place = dropOnRow(tree, ["Reading", "Work"], node$("GitHub"));
  expect(place).toEqual({ parent: "bar", index: 0 });
  expect(moveOps(tree, ["Reading", "Work"], place!)).toEqual([
    { op: "move", bookmark: "Reading", parent: "bar", index: 1 },
  ]);
  // Example (other) and GitHub into Reading's end.
  expect(moveOps(tree, ["GitHub", "Example"], { parent: "Reading", index: 0 })).toEqual([
    { op: "move", bookmark: "GitHub", parent: "Reading", index: 0 },
    { op: "move", bookmark: "Example", parent: "Reading", index: 1 },
  ]);
});

test("deleting a folder and its contents deletes each once", () => {
  expect(deleteOps(tree, ["Rust", "Work", "PRs", "Example"])).toEqual([
    { op: "delete", bookmark: "Work" },
    { op: "delete", bookmark: "Example" },
  ]);
});

test("a rename plus a move is one update and one move", () => {
  const state = { ...editState(node$("Docs")), title: "Reference", folder: "other" };
  expect(editorOps(tree, "default", state)).toEqual({
    ok: true,
    ops: [
      { op: "update", bookmark: "Docs", title: "Reference" },
      { op: "move", bookmark: "Docs", parent: "other", index: 1 },
    ],
  });
  // Nothing changed: no op at all.
  expect(editorOps(tree, "default", editState(node$("GitHub")))).toEqual({ ok: true, ops: [] });
});

test("an edit's typed URL is parsed; a bad one keeps the editor open", () => {
  const edit = { ...editState(node$("GitHub")), url: "github.com/new" };
  expect(editorOps(tree, "default", edit)).toEqual({
    ok: true,
    ops: [{ op: "update", bookmark: "GitHub", url: "https://github.com/new" }],
  });
  expect(editorOps(tree, "default", { ...edit, url: "no good" })).toEqual({ ok: false, reason: "invalidURL" });
});

test("an add is one create into the chosen folder", () => {
  const add = {
    mode: { kind: "addBookmark" as const },
    isFolder: false,
    title: "Site",
    url: "site.test",
    folder: "Work",
  };
  expect(editorOps(tree, "default", add)).toEqual({
    ok: true,
    ops: [
      {
        op: "create",
        id: null,
        browser_profile_id: "default",
        parent: "Work",
        index: null,
        kind: "url",
        title: "Site",
        url: "https://site.test",
        favicon_key: null,
        source_key: null,
        created_ms: null,
      },
    ],
  });
});

test("the reveal route names the bookmark to show", () => {
  expect(revealRoute("#/?reveal=bm_%2F1")).toBe("bm_/1");
  expect(revealRoute("#/")).toBeNull();
  expect(revealRoute("")).toBeNull();
});
