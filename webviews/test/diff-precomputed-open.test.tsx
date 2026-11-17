// The diff tab opens on a diff the host already has (Leo, 2026-11-05: "There's no reason for them to
// have a delay, even under load."): one it opened while the page booted, or one it precomputed when an
// agent's turn ended. A precomputed diff can be older than the work tree, so its fingerprint is the
// freshness baseline: when the files changed since, the new diff replaces it in one commit, with the
// files on screen kept until then and the reader's place put back, never a jump to the top.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { useDiffFreshness, usePrecomputedFingerprint } = await import("../src/diff-viewer/freshness");
const { initialAppState, reducer } = await import("../src/diff-viewer/state");
const { createDiffViewerStatus } = await import("../src/status");
const timing = await import("../src/diff-viewer/openTiming");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

function Viewer(props: {
  read: () => Promise<string | undefined>;
  fingerprint: string | undefined;
  refresh: () => void;
  reconcile: () => void;
  generation?: number;
  failedGeneration?: number | null;
  id?: number;
}) {
  const stale = useDiffFreshness(props.read, props.generation ?? 0, () => true, props.refresh, undefined, {
    fingerprint: props.fingerprint,
    id: props.id,
    reconcile: props.reconcile,
    failedGeneration: props.failedGeneration,
  });
  return <output>{stale ? "stale" : "fresh"}</output>;
}

test("a precomputed diff older than the work tree is reconciled on the first check, not left stale", async () => {
  let refreshed = 0;
  let reconciled = 0;
  const render = (generation: number) =>
    act(async () =>
      root.render(
        <Viewer
          key="older"
          generation={generation}
          read={async () => "now"}
          fingerprint="when-the-turn-ended"
          refresh={() => (refreshed += 1)}
          reconcile={() => (reconciled += 1)}
        />,
      ),
    );
  await render(0);
  await settle();
  expect(reconciled).toBe(1);
  expect(refreshed).toBe(0);
  expect(host.querySelector("output")?.textContent).toBe("fresh");
  // The reconcile's render (a new generation) is the baseline now: the next check finds nothing new.
  await render(1);
  await settle();
  dom.window.dispatchEvent(new dom.window.Event("focus"));
  await settle();
  expect(reconciled).toBe(1);
  expect(refreshed).toBe(0);
});

test("the reconcile's own load does not reconcile again while the open is in flight", async () => {
  // A reconcile bumps the render generation, and the precomputed fingerprint stays until the new
  // open answers: the check of that generation must start from what it reads, not the old baseline.
  let reconciled = 0;
  const render = (generation: number) =>
    act(async () =>
      root.render(
        <Viewer
          key="looping"
          generation={generation}
          read={async () => "now"}
          fingerprint="when-the-turn-ended"
          refresh={() => {}}
          reconcile={() => (reconciled += 1)}
        />,
      ),
    );
  await render(0);
  await settle();
  expect(reconciled).toBe(1);
  await render(1);
  await settle();
  await render(2);
  await settle();
  expect(reconciled).toBe(1);
  expect(host.querySelector("output")?.textContent).toBe("fresh");
});

test("a failed reconcile leaves the precomputed diff marked stale, not current", async () => {
  // The reconcile bumped the generation and its render failed: the precomputed diff is still on
  // screen, so the tree's fingerprint must not become the baseline.
  let reconciled = 0;
  const render = (generation: number, failedGeneration: number | null) =>
    act(async () =>
      root.render(
        <Viewer
          key="failed"
          generation={generation}
          failedGeneration={failedGeneration}
          read={async () => "now"}
          fingerprint="when-the-turn-ended"
          refresh={() => {}}
          reconcile={() => (reconciled += 1)}
        />,
      ),
    );
  await render(0, null);
  await settle();
  expect(reconciled).toBe(1);
  await render(1, null);
  await settle();
  await render(1, 1);
  await settle();
  expect(reconciled).toBe(1);
  expect(host.querySelector("output")?.textContent).toBe("stale");
});

test("a failed reconcile records its generation, and the reader's file that left the diff yields", () => {
  const status = createDiffViewerStatus("", { loading: false });
  const item = (path: string) =>
    ({ id: path, type: "diff", version: 0, fileDiff: { name: path, hunks: [{}] } }) as never;
  let state = initialAppState({ payload: {} } as never, status);
  state = reducer(state, { type: "append-items", items: [item("a.ts"), item("b.ts")] });
  state = reducer(state, { type: "reconcile" });
  state = reducer(state, { type: "end-reconcile" });
  expect(state.reconciling).toBe(false);
  expect(state.reconcileFailedGeneration).toBe(state.renderGeneration);

  state = reducer(state, { type: "set-active-item", itemId: "b.ts" });
  state = reducer(state, { type: "reconcile" });
  state = reducer(state, { type: "replace-items", items: [item("a.ts"), item("c.ts")] });
  expect(state.activeItemId).toBe("a.ts");
});

test("a reconcile's renames carry the reader's file and the comment draft to their new ids", () => {
  // Codex review of #36808 at bd9f2c5a (BLOCK P2): a second entry for a path renames the first one
  // (`a.ts` to `a.ts?deleted`, the new one is `a.ts?2`). A reconcile renamed only its staged items, so
  // the reader on `a.ts` fell back to the first file and the draft kept an id no file has.
  const status = createDiffViewerStatus("", { loading: false });
  const item = (id: string) => ({ id, type: "diff", version: 0, fileDiff: { name: "a.ts", hunks: [{}] } }) as never;
  let state = initialAppState({ payload: {} } as never, status);
  state = reducer(state, { type: "append-items", items: [item("z.ts"), item("a.ts")] });
  state = reducer(state, { type: "set-active-item", itemId: "a.ts" });
  state = reducer(state, { type: "set-draft", draft: { itemId: "a.ts", side: "additions", startLine: 2, endLine: 2 } });
  state = reducer(state, { type: "reconcile" });
  state = reducer(state, {
    type: "replace-items",
    items: [item("z.ts"), item("a.ts?deleted"), item("a.ts?2")],
    renames: [{ oldId: "a.ts", newId: "a.ts?deleted" }],
  });
  expect(state.activeItemId).toBe("a.ts?deleted");
  expect(state.draft?.itemId).toBe("a.ts?deleted");
  // Already-final ids from an old diff of the same shape are not moved by the new diff's renames.
  state = reducer(state, { type: "set-active-item", itemId: "a.ts?2" });
  state = reducer(state, { type: "reconcile" });
  state = reducer(state, {
    type: "replace-items",
    items: [item("z.ts"), item("a.ts?deleted"), item("a.ts?2")],
    renames: [{ oldId: "a.ts", newId: "a.ts?deleted" }],
  });
  expect(state.activeItemId).toBe("a.ts?2");
});

test("a later precompute with the same fingerprint gets its own first comparison", async () => {
  // Codex review of #36808 (follow-up F3): the one-check rule was keyed by the fingerprint alone, so a
  // second precompute that hashed the same skipped its check and stayed shown after later edits.
  let reconciled = 0;
  const render = (id: number, generation: number) =>
    act(async () =>
      root.render(
        <Viewer
          key="same-hash"
          id={id}
          generation={generation}
          read={async () => "edited"}
          fingerprint="same"
          refresh={() => {}}
          reconcile={() => (reconciled += 1)}
        />,
      ),
    );
  await render(1, 0);
  await settle();
  expect(reconciled).toBe(1);
  await render(2, 1);
  await settle();
  expect(reconciled).toBe(2);
});

test("a precompute cleared by a render with none, then made again at the same hash, is checked again", async () => {
  // Codex review of #36808 at 4bbb1758 (comment 6673248915, F1): the id restarted at 1 after a render
  // reported no precompute, so the second precompute was `1:X` again, matched the consumed key, and an
  // older diff stayed shown without reconciling.
  let reconciled = 0;
  let prepare: (fingerprint: string | undefined) => void = () => {};
  function Host({ generation }: { generation: number }) {
    const [precomputed, prepared] = usePrecomputedFingerprint();
    prepare = prepared;
    const stale = useDiffFreshness(
      async () => "edited",
      generation,
      () => true,
      () => {},
      undefined,
      {
        fingerprint: precomputed?.fingerprint,
        id: precomputed?.id,
        reconcile: () => (reconciled += 1),
      },
    );
    return <output>{stale ? "stale" : "fresh"}</output>;
  }
  await act(async () => root.render(<Host key="reset-id" generation={0} />));
  await act(async () => prepare("X"));
  await settle();
  expect(reconciled).toBe(1);
  // A plain render (no precompute) clears it, then a new precompute of the same tree arrives.
  await act(async () => root.render(<Host key="reset-id" generation={1} />));
  await act(async () => prepare(undefined));
  await settle();
  await act(async () => root.render(<Host key="reset-id" generation={2} />));
  await act(async () => prepare("X"));
  await settle();
  expect(reconciled).toBe(2);
});

test("a stale notice for one source is not shown for the next at the same generation", async () => {
  // Codex review of #36808 at 135615af (BLOCK F1): a failed reconcile marked the generation stale, and
  // switching sources (reset-diff) keeps the generation, so the new source inherited the notice.
  const render = (read: () => Promise<string | undefined>, failedGeneration: number | null) =>
    act(async () =>
      root.render(
        <Viewer
          key="source-switch"
          generation={1}
          failedGeneration={failedGeneration}
          read={read}
          fingerprint="when-the-turn-ended"
          refresh={() => {}}
          reconcile={() => {}}
        />,
      ),
    );
  await render(async () => "edited", 1);
  await settle();
  expect(host.querySelector("output")?.textContent).toBe("stale");
  // Another source: a new reader (memoized per source), the failure forgotten, the same generation.
  await render(async () => "other-source", null);
  await settle();
  expect(host.querySelector("output")?.textContent).toBe("fresh");
});

test("another source ends a reconcile and forgets its failure", () => {
  // Codex review of #36808 (follow-up F1): reset-diff kept `reconciling`, so the new source's render
  // took the reconcile path.
  const status = createDiffViewerStatus("", { loading: false });
  let state = initialAppState({ payload: {} } as never, status);
  state = reducer(state, { type: "reconcile" });
  state = reducer(state, { type: "reset-diff", status });
  expect(state.reconciling).toBe(false);
  state = reducer(reducer(state, { type: "reconcile" }), { type: "end-reconcile" });
  state = reducer(state, { type: "reset-diff", status });
  expect(state.reconcileFailedGeneration).toBeNull();
});

test("a precomputed diff that is still current is kept as it is", async () => {
  let reconciled = 0;
  await act(async () =>
    root.render(
      <Viewer
        key="current"
        read={async () => "same"}
        fingerprint="same"
        refresh={() => {}}
        reconcile={() => (reconciled += 1)}
      />,
    ),
  );
  await settle();
  expect(reconciled).toBe(0);
});

test("a reconcile keeps the files on screen until the new diff replaces them in one commit", () => {
  const status = createDiffViewerStatus("", { loading: false });
  const item = (path: string, version = 0) =>
    ({ id: path, type: "diff", version, fileDiff: { name: path, hunks: [{}] } }) as never;
  let state = initialAppState({ payload: {} } as never, status);
  state = reducer(state, { type: "append-items", items: [item("a.ts"), item("b.ts"), item("c.ts")] });
  state = reducer(state, { type: "set-active-item", itemId: "b.ts" });
  const generation = state.renderGeneration;

  state = reducer(state, { type: "reconcile" });
  expect(state.reconciling).toBe(true);
  expect(state.renderGeneration).toBe(generation + 1);
  expect(state.items.map((entry) => entry.id)).toEqual(["a.ts", "b.ts", "c.ts"]);

  state = reducer(state, { type: "replace-items", items: [item("a.ts", 1), item("b.ts", 1), item("d.ts", 1)] });
  expect(state.reconciling).toBe(false);
  expect(state.replaceCount).toBe(1);
  expect(state.items.map((entry) => entry.id)).toEqual(["a.ts", "b.ts", "d.ts"]);
  // The reader's file is still in the diff, so it stays the active one.
  expect(state.activeItemId).toBe("b.ts");

  // A plain refresh still starts over (and ends any reconcile).
  state = reducer(reducer(state, { type: "reconcile" }), { type: "refresh", status });
  expect(state.reconciling).toBe(false);
  expect(state.items).toEqual([]);
});

test("the open's timeline goes to the host once, when the first hunk has painted", async () => {
  timing.resetDiffOpenTimingForTesting();
  const sent: [string, any][] = [];
  const page = { call: async (op: string, params: unknown) => void sent.push([op, params]) } as never;
  timing.markDiffOpen("boot");
  timing.markDiffOpen("sessionOpened");
  timing.markDiffAdopted(true);
  timing.reportFirstHunk(page, 3);
  timing.reportFirstHunk(page, 3);
  await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(undefined)));
  await settle();
  expect(sent).toHaveLength(1);
  const [op, params] = sent[0]!;
  expect(op).toBe(timing.DIFF_SHOWN_OP);
  expect(params.files).toBe(3);
  expect(params.adopted).toBe(true);
  expect(Object.keys(params.marks)).toEqual(["boot", "sessionOpened", "firstHunk", "painted"]);
});
