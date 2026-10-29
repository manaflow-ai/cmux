// The Files page keeps its open folders, its selected row and the tree's scroll across a discard,
// saved when it hides. The host's own discard-time ask (`cmux.files.viewState`)
// still wins when it answered.
import { describe, expect, test } from "bun:test";
import type { PageClient } from "../shared/pageClient";
import { pageRoundTrip, scrollOf, withRestore } from "../shared/pageStateTesting";
import { FILES_PAGE, FilesStore } from "./store";
import type { FileEntry } from "./types";

const tree: Record<string, FileEntry[]> = {
  "": [
    { name: "Sources", kind: "directory" },
    { name: "README.md", kind: "file" },
  ],
  Sources: [{ name: "main.swift", kind: "file" }],
};

function host(viewState?: unknown): PageClient {
  return {
    async call<R>(op: string, params?: unknown): Promise<R> {
      if (op === "cmux.files.root") return { folder: "/w", name: "w", ...(viewState ? { viewState } : {}) } as R;
      if (op === "cmux.files.list")
        return { entries: tree[(params as { path: string }).path] ?? [], truncated: false } as R;
      throw new Error(`unexpected ${op}`);
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
}

describe("Files page state", () => {
  test("a hide, a discard and a restore give the next document the same tree and scroll", async () => {
    const store = new FilesStore(host());
    const trip = pageRoundTrip(FILES_PAGE, { scroll: { tree: 260 }, inputs: () => store.pageInputs() });
    await store.start();
    store.expand("Sources");
    store.select("Sources/main.swift");

    const { client, after } = trip.restore();
    const restored = new FilesStore(withRestore(host(), client));
    await restored.start();
    expect(restored.getSnapshot()).toMatchObject({ selected: "Sources/main.swift" });
    expect([...restored.getSnapshot().expanded]).toEqual(["Sources"]);
    expect(scrollOf(after, "tree")).toBe(260);
  });

  test("the host's discard-time answer wins over the hide-time save", async () => {
    const trip = pageRoundTrip(FILES_PAGE, { inputs: () => ({ expanded: ["Sources"], selected: "README.md" }) });
    const { client } = trip.restore();
    const restored = new FilesStore(withRestore(host({ expanded: [], selected: "Sources", scroll: 0 }), client));
    await restored.start();
    expect(restored.getSnapshot().selected).toBe("Sources");
    expect([...restored.getSnapshot().expanded]).toEqual([]);
  });
});
