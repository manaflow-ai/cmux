// The diff tab opens on a diff the host already has (Leo, 2026-11-05: "There's no reason for them to
// have a delay, even under load."): one it opened while the page booted, or one it precomputed when an
// agent's turn ended. A precomputed diff can be older than the work tree, so its fingerprint is the
// freshness baseline: when the files changed since, the new diff replaces it in one commit, with the
// files on screen kept until then and the reader's place put back, never a jump to the top.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
const { useDiffFreshness } = await import("../src/diff-viewer/freshness");
const { initialAppState, reducer } = await import("../src/diff-viewer/state");
const { createDiffViewerStatus } = await import("../src/status");
const timing = await import("../src/diff-viewer/openTiming");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

function Viewer(props: {
  read: () => Promise<string | undefined>;
  fingerprint: string | undefined;
  refresh: () => void;
  reconcile: () => void;
  generation?: number;
}) {
  const stale = useDiffFreshness(props.read, props.generation ?? 0, () => true, props.refresh, undefined, {
    fingerprint: props.fingerprint,
    reconcile: props.reconcile,
  });
  return <output>{stale ? "stale" : "fresh"}</output>;
}

test("a precomputed diff older than the work tree is reconciled on the first check, not left stale", async () => {
  let refreshed = 0;
  let reconciled = 0;
  await act(async () =>
    root.render(
      <Viewer
        key="older"
        read={async () => "now"}
        fingerprint="when-the-turn-ended"
        refresh={() => (refreshed += 1)}
        reconcile={() => (reconciled += 1)}
      />,
    ),
  );
  await settle();
  expect(reconciled).toBe(1);
  expect(refreshed).toBe(0);
  expect(host.querySelector("output")?.textContent).toBe("fresh");
  // The reconciled diff is the baseline now: the next check finds nothing new.
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
