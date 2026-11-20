// Another file shown in the same tab (a followed link, Back, Forward) brings its own comments, saved
// table widths and remote-image grant (the host answers none after a file change); nothing of the
// previous file's stays.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { MarkdownStore } from "../src/pages/markdown/store";

const files: Record<string, Record<string, unknown>> = {
  "/a.md": {
    path: "/a.md",
    text: "# A\n",
    hash: "a",
    comments: { v: 1, comments: [{ id: "a-1" }] },
    tableWidths: { "0": [120] },
    remoteImageBase: "/remote/a/",
  },
  "/b.md": { path: "/b.md", text: "# B\n", hash: "b" },
};

function store() {
  const client = {
    async call<R>(op: string, params: unknown): Promise<R> {
      if (op === "cmux.markdown.config") return files["/a.md"] as R;
      if (op === "cmux.markdown.open") {
        const path = (params as { path: string }).path;
        // The host drops the remote-image approval whenever the tab's file changes
        // (FilePageProvider.open), so a reply to open never carries the previous file's grant.
        const { remoteImageBase: _grant, ...reply } = files[path]!;
        return reply as R;
      }
      return {} as R;
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  return new MarkdownStore(client);
}

test("a followed link and Back swap the file's comments and table widths, and drop the image grant", async () => {
  const markdown = store();
  await markdown.start();
  expect(markdown.getState().config).toMatchObject({
    remoteImageBase: "/remote/a/",
    comments: files["/a.md"]!.comments,
  });

  await markdown.navigate("/b.md", "", 0);
  const b = markdown.getState().config!;
  expect(b.path).toBe("/b.md");
  expect(b.comments).toBeUndefined();
  expect(b.tableWidths).toBeUndefined();
  expect(b.remoteImageBase).toBeUndefined();

  await markdown.go(-1, 0);
  const a = markdown.getState().config!;
  expect(a.path).toBe("/a.md");
  expect(a.comments).toEqual(files["/a.md"]!.comments);
  expect(a.tableWidths).toEqual(files["/a.md"]!.tableWidths);
  // The grant was dropped with the file change: A asks again, and nothing of B's was kept.
  expect(a.remoteImageBase).toBeUndefined();
});
