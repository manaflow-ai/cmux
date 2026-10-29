// A hidden Markdown tab's page may be discarded (`memoryDiscardInternalPages`): the
// host asks `cmux.markdown.viewState` first, and the next page's config carries the answer back as
// `viewState`. The place is anchored to the heading above the top of the view (Chrome's scroll
// anchoring, scroll_anchor.cc), so content that moves above it does not lose the reader's place.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { MarkdownStore, type Schedule } from "../src/pages/markdown/store";
import {
  anchoredScrollTop,
  markdownHeadingBoxes,
  markdownScrollAnchor,
  markdownViewStateOf,
} from "../src/pages/markdown/viewState";

const headings = [
  { text: "Intro", top: 0 },
  { text: "Usage", top: 400 },
  { text: "Notes", top: 900 },
  { text: "Usage", top: 1500 },
];

test("the anchor is the heading at or above the top of the view, with its occurrence and offset", () => {
  expect(markdownScrollAnchor(headings, 950)).toEqual({ heading: "Notes", occurrence: 0, offset: 50 });
  expect(markdownScrollAnchor(headings, 1600)).toEqual({ heading: "Usage", occurrence: 1, offset: 100 });
  expect(markdownScrollAnchor([{ text: "Late", top: 300 }], 100)).toBeUndefined();
});

test("the restored scroll follows its heading when the content above it moved", () => {
  const anchor = markdownScrollAnchor(headings, 1600)!;
  const grown = headings.map((heading) => ({ ...heading, top: heading.top + 250 }));
  expect(anchoredScrollTop(grown, { scroll: 1600, anchor })).toBe(1850);
  expect(anchoredScrollTop([{ text: "Other", top: 0 }], { scroll: 1600, anchor })).toBe(1600);
  expect(anchoredScrollTop(headings, { scroll: 77 })).toBe(77);
});

test("hidden headings have no place: a source-mode page saves its plain scroll", () => {
  // The rich document stays mounted but hidden under the source view: every heading's box is empty.
  const scroller = {
    scrollTop: 640,
    getBoundingClientRect: () => ({ top: 80, width: 600, height: 400 }),
    querySelectorAll: () =>
      ["Intro", "Usage"].map((text) => ({
        textContent: text,
        getBoundingClientRect: () => ({ top: 0, width: 0, height: 0 }),
      })),
  } as unknown as HTMLElement;
  const boxes = markdownHeadingBoxes(scroller);
  expect(boxes).toEqual([]);
  const anchor = markdownScrollAnchor(boxes, 640);
  expect(anchor).toBeUndefined();
  expect(anchoredScrollTop(boxes, { scroll: 640 })).toBe(640);
});

test("a malformed viewState is ignored; a good one keeps its mode", () => {
  expect(markdownViewStateOf(null)).toBeNull();
  expect(markdownViewStateOf({ scroll: "far" })).toBeNull();
  expect(markdownViewStateOf({ scroll: -5, mode: "other", anchor: { heading: 1 } })).toEqual({ scroll: 0 });
  expect(markdownViewStateOf({ scroll: 10, mode: "source" })).toEqual({ scroll: 10, mode: "source" });
});

function harness(config: Record<string, unknown>) {
  const edits: string[] = [];
  const client = {
    async call<R>(op: string, params?: unknown): Promise<R> {
      if (op === "cmux.markdown.config") return config as R;
      if (op === "cmux.markdown.edited") {
        edits.push((params as { text: string }).text);
        return { accepted: "kept" } as R;
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
  const neverEnds: Schedule = () => () => {};
  return { store: new MarkdownStore(client, neverEnds, neverEnds), edits };
}

const file = { path: "/a.md", text: "# A\n", hash: "h", assetBase: "/assets/" };

test("a config's viewState opens the page in its mode and gives its place back once", async () => {
  const saved = { scroll: 300, anchor: { heading: "A", occurrence: 0, offset: 300 }, mode: "source" };
  const { store } = harness({ ...file, viewState: saved });
  await store.start();
  expect(store.getState().mode).toBe("source");
  expect(store.takeRestoredView()).toEqual(saved as never);
  expect(store.takeRestoredView()).toBeNull();
});

test("a config without viewState has no place to restore", async () => {
  const { store } = harness(file);
  await store.start();
  expect(store.takeRestoredView()).toBeNull();
});

test("an edit not reported yet goes to the host before the page answers its view state", async () => {
  const { store, edits } = harness(file);
  await store.start();
  store.setMode("source");
  store.setSource("# A\nfirst\n");
  store.setSource("# A\nfirst\nsecond\n");
  expect(edits).toHaveLength(1);
  store.reportPendingEdit();
  expect(edits).toEqual(["# A\nfirst\n", "# A\nfirst\nsecond\n"]);
  store.reportPendingEdit();
  expect(edits).toHaveLength(2);
});

test("the view state carries the link history, and a page made again on its file can go back", async () => {
  const configs: Record<string, unknown> = {
    "/a.md": file,
    "/b.md": { ...file, path: "/b.md", text: "# B\n", hash: "hb" },
  };
  let config: unknown = file;
  const client = {
    async call<R>(op: string, params?: unknown): Promise<R> {
      if (op === "cmux.markdown.config") return config as R;
      if (op === "cmux.markdown.open") return configs[(params as { path: string }).path] as R;
      if (op === "cmux.markdown.history") return {} as R;
      throw new Error(`unexpected ${op}`);
    },
    async subscribe() {
      return () => {};
    },
    handle() {
      return () => {};
    },
  } satisfies PageClient;
  const neverEnds: Schedule = () => () => {};
  const before = new MarkdownStore(client, neverEnds, neverEnds);
  await before.start();
  await before.navigate("/b.md", "", 120);
  const answer = before.viewState(40, undefined);
  expect(answer.dirty).toBe(false);
  const saved = answer.view as { history: { entries: { path: string; scroll: number }[]; index: number } };
  expect(saved.history.index).toBe(1);
  expect(saved.history.entries.map((entry) => [entry.path, entry.scroll])).toEqual([
    ["/a.md", 120],
    ["/b.md", 40],
  ]);

  // The host made the next page on the file the tab showed, B, with the saved view.
  config = { ...(configs["/b.md"] as object), viewState: answer.view };
  const after = new MarkdownStore(client, neverEnds, neverEnds);
  await after.start();
  expect(after.getState().canBack).toBe(true);
  const back = await after.go(-1, 0);
  expect(back?.path).toBe("/a.md");
  expect(back?.scroll).toBe(120);
});

test("a malformed link history is not put back", () => {
  const view = markdownViewStateOf({
    scroll: 0,
    history: { entries: [{ path: "/a.md", anchor: "", scroll: 0 }], index: 3 },
  });
  expect(view?.history).toBeUndefined();
});

test("the view state says the page holds edits not on disk", async () => {
  const { store } = harness(file);
  await store.start();
  store.setMode("source");
  store.setSource("# A\nedited\n");
  expect(store.viewState(0, undefined).dirty).toBe(true);
});
