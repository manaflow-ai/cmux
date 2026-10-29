// A hidden Files tab's page may be discarded (`memoryDiscardInternalPages`): the host
// asks `cmux.files.viewState` first and gives the answer back once in the next page's `root` reply,
// so the tree opens the same folders, keeps its selected row and scrolls back.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { FilesStore } from "../src/pages/files/store";
import { filesViewStateOf, type FileEntry } from "../src/pages/files/types";

const tree: Record<string, FileEntry[]> = {
  "": [
    { name: "Sources", kind: "directory" },
    { name: "README.md", kind: "file" },
  ],
  Sources: [
    { name: "App", kind: "directory" },
    { name: "main.swift", kind: "file" },
  ],
  "Sources/App": [{ name: "View.swift", kind: "file" }],
};

function client(viewState?: unknown): { client: PageClient; listed: string[] } {
  const listed: string[] = [];
  return {
    listed,
    client: {
      async call<R>(op: string, params?: unknown): Promise<R> {
        if (op === "cmux.files.root") return { folder: "/w", name: "w", ...(viewState ? { viewState } : {}) } as R;
        if (op === "cmux.files.list") {
          const path = (params as { path: string }).path;
          listed.push(path);
          return { entries: tree[path] ?? [], truncated: false } as R;
        }
        throw new Error(`unexpected ${op}`);
      },
      async subscribe() {
        return () => {};
      },
      handle() {
        return () => {};
      },
    },
  };
}

test("the view state names the open folders, the selected row and the scroll", async () => {
  const { client: host } = client();
  const store = new FilesStore(host);
  await store.start();
  store.expand("Sources");
  store.expand("Sources/App");
  store.select("Sources/App/View.swift");
  expect(store.viewState(320)).toEqual({
    expanded: ["Sources", "Sources/App"],
    selected: "Sources/App/View.swift",
    scroll: 320,
  });
});

test("a page made again opens the saved folders, keeps the selection and scrolls back once", async () => {
  const { client: host, listed } = client({
    expanded: ["Sources", "Sources/App"],
    selected: "Sources/App/View.swift",
    scroll: 320,
  });
  const store = new FilesStore(host);
  await store.start();
  expect(listed.sort()).toEqual(["", "Sources", "Sources/App"]);
  const snapshot = store.getSnapshot();
  expect(snapshot.selected).toBe("Sources/App/View.swift");
  expect(snapshot.rows.map((row) => row.path)).toContain("Sources/App/View.swift");
  expect(store.takeRestoredScroll()).toBe(320);
  expect(store.takeRestoredScroll()).toBeNull();
});

test("a page with no saved state starts at the root with its first row selected", async () => {
  const { client: host, listed } = client();
  const store = new FilesStore(host);
  await store.start();
  expect(listed).toEqual([""]);
  expect(store.getSnapshot().selected).toBe("Sources");
  expect(store.takeRestoredScroll()).toBeNull();
});

test("a malformed view state is ignored", () => {
  expect(filesViewStateOf(null)).toBeNull();
  expect(filesViewStateOf({ expanded: "Sources" })).toBeNull();
  expect(filesViewStateOf({ expanded: ["Sources", 3], scroll: -4 })).toEqual({ expanded: ["Sources"], scroll: 0 });
});
