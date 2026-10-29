// A hidden diff tab's page may be discarded (`memoryDiscardInternalPages`): the host
// asks `cmux.diff.viewState` first and gives the answer back as the next page's `payload.viewState`.
// The page saves the file at the top and how far into it, the files the reader unfolded that open
// folded, and the options that last for the tab.
import { expect, test } from "bun:test";
import type { DiffItem } from "../src/diff-stream";
import { initialAppState } from "../src/diff-viewer/state";
import { diffViewState, diffViewStateOf, itemsToUnfold } from "../src/diff-viewer/viewState";
import { initialDiffViewerStatus } from "../src/status";
import type { DiffViewerConfig } from "../src/types";

const item = (id: string, collapsed: boolean, deferred = false): DiffItem =>
  ({
    id,
    type: "diff",
    collapsed,
    fileDiff: { name: id, ...(deferred ? { cmuxDeferredReason: "large" } : {}) },
  }) as DiffItem;

const options = (overrides: Record<string, boolean> = {}) =>
  ({
    collapsed: false,
    hideImports: false,
    loadFullFiles: false,
    richPreview: false,
    expandUnchanged: false,
    ...overrides,
  }) as never;

const opensFolded = (entry: DiffItem) => entry.fileDiff?.cmuxDeferredReason != null;

test("the state names the unfolded files that open folded, the anchor and the tab options", () => {
  const items = [item("a.ts", false), item("big.lock", false, true), item("gen.js", true, true)];
  const state = diffViewState(items, { itemId: "a.ts", offset: 320 }, options({ hideImports: true }), opensFolded);
  expect(state).toEqual({
    anchor: { itemId: "a.ts", offset: 320 },
    expanded: ["big.lock"],
    options: { collapsed: false, hideImports: true, loadFullFiles: false, richPreview: false },
  });
  expect(diffViewState(items, null, options(), opensFolded).anchor).toBeUndefined();
});

test("the state reads back through JSON; malformed parts are dropped", () => {
  const items = [item("big.lock", false, true)];
  const saved = diffViewState(items, { itemId: "big.lock", offset: 40 }, options({ loadFullFiles: true }), opensFolded);
  expect(diffViewStateOf(JSON.parse(JSON.stringify(saved)))).toEqual(saved);
  expect(diffViewStateOf(null)).toBeNull();
  expect(
    diffViewStateOf({
      anchor: { itemId: 3, offset: 1 },
      expanded: ["x", 4],
      options: { hideImports: "yes", richPreview: true },
    }),
  ).toEqual({ expanded: ["x"], options: { richPreview: true } });
});

test("only saved files that are back and folded unfold", () => {
  const saved = diffViewStateOf({ expanded: ["big.lock", "gone.ts", "open.ts"] })!;
  const items = [item("big.lock", true, true), item("open.ts", false), item("other.ts", true)];
  expect(itemsToUnfold(items, saved)).toEqual(["big.lock"]);
});

test("the first state of a restored page has its tab options", () => {
  const config = {
    payload: { viewState: { expanded: [], options: { hideImports: true, richPreview: true } } },
  } as unknown as DiffViewerConfig;
  const state = initialAppState(
    config,
    initialDiffViewerStatus(config, (key: string) => key),
  );
  expect(state.options.hideImports).toBe(true);
  expect(state.options.richPreview).toBe(true);
  expect(state.options.loadFullFiles).toBe(false);
});
