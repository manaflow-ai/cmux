// A hidden Markdown tab's page may be discarded (`memoryDiscardInternalPages`, p07-memory-026): the
// host asks `cmux.markdown.viewState` first, and the next page's config carries the answer back as
// `viewState`. The place is anchored to the heading above the top of the view (Chrome's scroll
// anchoring, scroll_anchor.cc), so content that moves above it does not lose the reader's place.
import { expect, test } from "bun:test";
import type { PageClient } from "../src/pages/shared/pageClient";
import { MarkdownStore, type Schedule } from "../src/pages/markdown/store";
import { anchoredScrollTop, markdownScrollAnchor, markdownViewStateOf } from "../src/pages/markdown/viewState";

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
