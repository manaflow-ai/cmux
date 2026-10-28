// The Markdown tab navigates like a browser page (plans/cmux-next/markdown-omnibar-DESIGN.md
// section 2b): a followed Markdown link or heading anchor pushes an entry on the tab's history,
// Back and Forward walk it and put the scroll back, Reload reads the file from disk again and
// keeps the scroll, a path typed in the omnibar opens as a new entry, and every history change
// tells the host (`cmux.markdown.history`) so the native Back and Forward buttons follow.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { MARKDOWN_HISTORY_OP } from "../src/pages/markdown/host";
import { LinkRouter } from "../src/pages/markdown/linkRouter";
import type { ResolvedLink } from "../src/pages/markdown/links";
import { MarkdownStore } from "../src/pages/markdown/store";

/** A host with files on a fake disk; `disk` can change between calls. */
function harness(disk: Record<string, string>) {
  const history: { canBack: boolean; canForward: boolean }[] = [];
  const opens: string[] = [];
  const file = (path: string) => ({ path, text: disk[path], hash: `${path}:${disk[path]}`, assetBase: "/assets/" });
  const client = {
    async call<R>(op: string, params: unknown): Promise<R> {
      if (op === "cmux.markdown.config") return file("/a.md") as R;
      if (op === "cmux.markdown.open") {
        const path = (params as { path: string }).path;
        opens.push(path);
        if (!(path in disk)) throw new Error("not found");
        return file(path) as R;
      }
      if (op === MARKDOWN_HISTORY_OP) {
        history.push(params as { canBack: boolean; canForward: boolean });
        return {} as R;
      }
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  const store = new MarkdownStore(client);
  let scrollTop = 0;
  const anchors: string[] = [];
  const resolved: Record<string, ResolvedLink> = {
    "b.md": { exists: true, path: "/b.md", kind: "markdown" },
  };
  const router = new LinkRouter({
    store,
    client,
    resolver: { get: (path) => resolved[path] },
    scrollToAnchor: (anchor) => {
      anchors.push(anchor);
      scrollTop = 500;
      return true;
    },
    scroll: { get: () => scrollTop, set: (top) => (scrollTop = top) },
  });
  return {
    store,
    router,
    history,
    opens,
    anchors,
    scroll: { get: () => scrollTop, set: (top: number) => (scrollTop = top) },
  };
}

test("a followed Markdown link pushes an entry; Back and Forward walk it and restore the scroll", async () => {
  const h = harness({ "/a.md": "# A\n", "/b.md": "# B\n" });
  await h.store.start();
  h.scroll.set(120);

  await h.router.follow("b.md");
  expect(h.store.getState().config?.path).toBe("/b.md");
  expect(h.store.getState()).toMatchObject({ canBack: true, canForward: false });
  h.scroll.set(40);

  await h.router.go(-1);
  expect(h.store.getState().config?.path).toBe("/a.md");
  expect(h.scroll.get()).toBe(120);
  expect(h.store.getState()).toMatchObject({ canBack: false, canForward: true });

  await h.router.go(1);
  expect(h.store.getState().config?.path).toBe("/b.md");
  expect(h.scroll.get()).toBe(40);
  expect(h.store.getState()).toMatchObject({ canBack: true, canForward: false });
});

test("a heading anchor pushes an entry in the same file; Back returns to where the reader was", async () => {
  const h = harness({ "/a.md": "# A\n\n## Usage\n" });
  await h.store.start();
  h.scroll.set(80);

  await h.router.follow("#usage");
  expect(h.anchors).toEqual(["usage"]);
  expect(h.store.getState()).toMatchObject({ canBack: true, canForward: false });
  expect(h.store.getState().config?.path).toBe("/a.md");

  await h.router.go(-1);
  expect(h.scroll.get()).toBe(80);
  expect(h.store.getState()).toMatchObject({ canBack: false, canForward: true });

  // The same anchor again from where it already is adds no second entry.
  await h.router.go(1);
  await h.router.follow("#usage");
  expect(h.store.getState()).toMatchObject({ canBack: true, canForward: false });
  await h.router.go(-1);
  expect(h.store.getState().canBack).toBe(false);
});

test("Reload reads the file from disk again and keeps the scroll and the history", async () => {
  const disk = { "/a.md": "# A\n", "/b.md": "# B\n" };
  const h = harness(disk);
  await h.store.start();
  await h.router.follow("b.md");
  h.scroll.set(300);
  disk["/b.md"] = "# B, edited elsewhere\n";

  await h.router.reload();
  expect(h.opens.at(-1)).toBe("/b.md");
  expect(h.store.getState().source).toBe("# B, edited elsewhere\n");
  expect(h.store.getState().config?.text).toBe("# B, edited elsewhere\n");
  expect(h.scroll.get()).toBe(300);
  expect(h.store.getState()).toMatchObject({ canBack: true, canForward: false });
});

test("a path typed in the omnibar opens as a new history entry", async () => {
  const h = harness({ "/a.md": "# A\n", "/c.md": "# C\n" });
  await h.store.start();

  await h.router.open("/c.md");
  expect(h.store.getState().config?.path).toBe("/c.md");
  expect(h.store.getState()).toMatchObject({ canBack: true, canForward: false });
  await h.router.go(-1);
  expect(h.store.getState().config?.path).toBe("/a.md");
});

test("every history change tells the host, so the native Back and Forward buttons follow", async () => {
  const h = harness({ "/a.md": "# A\n", "/b.md": "# B\n" });
  await h.store.start();
  await h.router.follow("b.md");
  await h.router.go(-1);
  expect(h.history).toEqual([
    { canBack: false, canForward: false },
    { canBack: true, canForward: false },
    { canBack: false, canForward: true },
  ]);
});
