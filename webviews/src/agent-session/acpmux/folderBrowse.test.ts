// The folder browser's listings (folderBrowse.ts): one directory a page at a time, an answer for a
// directory already left is dropped, and an acpmux without `_acpmux/browse` reads as "update it".
import { expect, test } from "bun:test";
import {
  BROWSE_PAGE,
  browseCrumbs,
  browseFailure,
  FolderBrowse,
  opensAsFolder,
  type BrowseParams,
  type BrowseReply,
  type BrowseView,
} from "./folderBrowse";

type Asked = { params: BrowseParams; resolve(reply: BrowseReply): void; reject(error: unknown): void };

function machine() {
  const asked: Asked[] = [];
  const views: BrowseView[] = [];
  const list = (params: BrowseParams) =>
    new Promise<BrowseReply>((resolve, reject) => asked.push({ params, resolve, reject }));
  const browse = new FolderBrowse(list, "big-red", (view) => views.push(view), 60_000);
  return { asked, views, browse };
}

const dir = (name: string, parent = "/home/leo") => ({ name, path: `${parent}/${name}`, kind: "dir" as const });
const reply = (
  path: string | null,
  entries: BrowseReply["entries"],
  extra: Partial<BrowseReply> = {},
): BrowseReply => ({
  path,
  parent: path ? path.split("/").slice(0, -1).join("/") || "/" : null,
  home: "/home/leo",
  entries,
  total: entries.length,
  offset: 0,
  ...extra,
});
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("asks the peer for one page of folders only, of the directory shown", () => {
  const { asked, browse } = machine();
  browse.open(null);
  browse.open("/home/leo/src");
  expect(asked.map((a) => a.params)).toEqual([
    { peer: "big-red", dirsOnly: true, limit: BROWSE_PAGE },
    { peer: "big-red", path: "/home/leo/src", dirsOnly: true, limit: BROWSE_PAGE },
  ]);
});

test("an answer for a directory already left is dropped", async () => {
  const { asked, browse } = machine();
  browse.open("/home/leo/slow");
  browse.open("/home/leo/src");
  asked[1]!.resolve(reply("/home/leo/src", [dir("cmux", "/home/leo/src")]));
  await settle();
  // The slow folder answers last; the view stays on the folder the person moved to.
  asked[0]!.resolve(reply("/home/leo/slow", [dir("stale", "/home/leo/slow")]));
  await settle();
  expect(browse.view.path).toBe("/home/leo/src");
  expect(browse.view.entries.map((e) => e.name)).toEqual(["cmux"]);
});

test("a closed browser drops every answer still out", async () => {
  const { asked, views, browse } = machine();
  browse.open("/home/leo");
  const before = views.length;
  browse.dispose();
  asked[0]!.resolve(reply("/home/leo", [dir("src")]));
  await settle();
  expect(views.length).toBe(before);
});

test("pages: the next page is asked once, from the reply's offset, and appended", async () => {
  const { asked, browse } = machine();
  browse.open("/home/leo");
  asked[0]!.resolve(reply("/home/leo", [dir("a"), dir("b")], { total: 3, nextOffset: 2 }));
  await settle();
  expect(browse.view.more).toBe(2);
  browse.more();
  browse.more();
  expect(asked.length).toBe(2);
  expect(asked[1]!.params).toEqual({
    peer: "big-red",
    path: "/home/leo",
    dirsOnly: true,
    limit: BROWSE_PAGE,
    offset: 2,
  });
  asked[1]!.resolve(reply("/home/leo", [dir("c")], { total: 3, offset: 2 }));
  await settle();
  expect(browse.view.entries.map((e) => e.name)).toEqual(["a", "b", "c"]);
  expect(browse.view.more).toBeUndefined();
  browse.more();
  expect(asked.length).toBe(2);
});

test("a page that arrives after the person moved on is dropped", async () => {
  const { asked, browse } = machine();
  browse.open("/home/leo");
  asked[0]!.resolve(reply("/home/leo", [dir("a")], { nextOffset: 1 }));
  await settle();
  browse.more();
  browse.open("/home/leo/a");
  asked[1]!.resolve(reply("/home/leo", [dir("late")], { offset: 1 }));
  await settle();
  expect(browse.view.path).toBe("/home/leo/a");
  expect(browse.view.entries).toEqual([]);
});

test("the typed truncation is kept for the quiet line", async () => {
  const { asked, browse } = machine();
  browse.open("/home/leo/node_modules");
  asked[0]!.resolve(reply("/home/leo/node_modules", [dir("x")], { truncated: { reason: "cap", scanned: 5000 } }));
  await settle();
  expect(browse.view.truncated).toEqual({ reason: "cap", scanned: 5000 });
});

test("an older acpmux (-32601), a refused folder and a down machine read apart", async () => {
  expect(browseFailure({ code: -32601 })).toBe("unsupported");
  expect(browseFailure({ code: "transport.method_refused" })).toBe("unsupported");
  expect(browseFailure({ code: -32602, reason: "browse.outside_roots" })).toBe("outside");
  expect(browseFailure({ code: -32603, reason: "peer_unreachable" })).toBe("unreachable");
  expect(browseFailure({ code: -32602, reason: "browse.not_directory" })).toBe("failed");
  const { asked, browse } = machine();
  browse.open(null);
  asked[0]!.reject({ code: -32601, message: "Method not found" });
  await settle();
  expect(browse.view.failure).toBe("unsupported");
  expect(browse.view.loading).toBe(false);
});

test("a machine that never answers is told as unreachable", async () => {
  let failed: (view: BrowseView) => void = () => undefined;
  const told = new Promise<BrowseView>((resolve) => (failed = resolve));
  const browse = new FolderBrowse(
    () => new Promise<BrowseReply>(() => undefined),
    "big-red",
    (view) => view.failure && failed(view),
    0,
  );
  browse.open(null);
  expect((await told).failure).toBe("unreachable");
});

test("links open only when they lead to a folder inside the machine's start folders", () => {
  expect(opensAsFolder({ name: "a", path: "/a", kind: "dir" })).toBe(true);
  expect(opensAsFolder({ name: "l", path: "/l", kind: "symlink", target: "dir" })).toBe(true);
  expect(opensAsFolder({ name: "l", path: "/l", kind: "symlink", target: "missing" })).toBe(false);
  expect(opensAsFolder({ name: "o", path: "/o", kind: "dir", outside: true })).toBe(false);
  expect(opensAsFolder({ name: "f", path: "/f", kind: "file" })).toBe(false);
});

test("crumbs start at ~ inside home, else at /", () => {
  expect(browseCrumbs("/home/leo/src/cmux", "/home/leo").map((c) => c.name)).toEqual(["~", "src", "cmux"]);
  expect(browseCrumbs("/home/leo/src/cmux", "/home/leo").at(-1)!.path).toBe("/home/leo/src/cmux");
  expect(browseCrumbs("/srv/data", "/home/leo").map((c) => c.path)).toEqual(["/", "/srv", "/srv/data"]);
});
