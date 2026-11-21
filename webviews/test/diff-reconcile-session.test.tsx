// A precomputed diff older than the work tree is reconciled: a new session streams the new diff while
// the old one stays on screen. Codex review of #36808 (follow-ups F1, F2): the render's cleanup closed
// the shown session as soon as the reconcile began, and the new session cleared the precomputed
// fingerprint at once, so a reconcile that failed left the old files with a closed (or a failed)
// session behind them and no stale baseline. The shown session now stays active until the new diff
// commits, and stays the active one when the reconcile fails.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { until } from "./support/until";
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
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, useRef } = await import("react");
const { createRoot } = await import("react-dom/client");
const { loadDiffViewerLabels, createDiffViewerLabelResolver } = await import("../src/labels");
await loadDiffViewerLabels("en");
const { useRenderDiff } = await import("../src/diff-viewer/useRenderDiff");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const label = createDiffViewerLabelResolver(undefined, { language: "en" });
const source = { kind: "unstaged", repoRoot: "/repo" } as const;
type Session = { sessionId: string; capabilityToken: string };

async function reconcile(
  patchResponse: () => Promise<Response>,
  freshExtra: Record<string, unknown> = {},
  whileStreaming?: () => void,
) {
  const calls: [string, unknown][] = [];
  const opens: ((value: unknown) => void)[] = [];
  const transport = {
    kind: "page",
    request: ({ method, params }: { method: string; params?: unknown }) => {
      calls.push([method, params]);
      if (method === "sessionOpen") return new Promise((resolve) => opens.push(resolve));
      return Promise.resolve({ type: "sessionClosed" });
    },
  };
  const opened = (id: string, extra: Record<string, unknown> = {}) => ({
    type: "sessionOpened",
    value: {
      sessionId: id,
      source,
      patch: { id: `cmux-page://cmux.diff/__patch/${id}/patch.diff` },
      generatedPaths: [],
      ...extra,
    },
  });
  const savedFetch = globalThis.fetch;
  let fetches = 0;
  globalThis.fetch = (async () => (fetches++ === 0 ? new Response("") : patchResponse())) as unknown as typeof fetch;
  const config = { payload: { capabilityToken: "token", sessionSource: source } } as never;
  const actions: string[] = [];
  const dispatched: { type: string; [key: string]: unknown }[] = [];
  const prepared: (string | undefined)[] = [];
  const patchURLs: string[] = [];
  const state = { reconciling: false, options: { collapsed: false }, generatedPaths: [] };
  let active!: { current: Session | null };
  let retained!: { current: Session | null };

  function Viewer({ generation }: { generation: number }) {
    const activeRef = useRef<Session | null>(null);
    const retainedRef = useRef<Session | null>(null);
    active = activeRef;
    retained = retainedRef;
    const adopted = useRef(null);
    const latest = useRef(state as never);
    const hooks = useRef({ retained: retainedRef, prepared: (f: string | undefined) => void prepared.push(f) });
    const close = () => {
      const session = activeRef.current;
      activeRef.current = null;
      return session
        ? transport.request({ method: "sessionClose", params: session }).then(() => {})
        : Promise.resolve();
    };
    useRenderDiff(
      config,
      transport as never,
      label,
      (action: { type: string }) => {
        actions.push(action.type);
        dispatched.push(action);
      },
      latest,
      (url: string) => void patchURLs.push(url),
      activeRef as never,
      close,
      source as never,
      () => {},
      generation,
      adopted,
      false,
      false,
      hooks as never,
    );
    return null;
  }

  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<Viewer generation={1} />));
    await act(async () => opens.shift()!(opened("warm", { prepared: "warm", fingerprint: "when-the-turn-ended" })));
    await until(
      () => active.current?.sessionId === "warm",
      () => act(async () => {}),
    );
    calls.length = 0;
    // App's reconcile: the shown session is kept, then the reconciling generation renders.
    retained.current = active.current;
    state.reconciling = true;
    await act(async () => root.render(<Viewer generation={2} />));
    expect(calls.map(([method]) => method)).toEqual(["sessionOpen"]);
    await act(async () => opens.shift()!(opened("fresh", freshExtra)));
    if (whileStreaming) {
      await act(async () => whileStreaming());
      // Taken now: the unmount below closes whatever is still open.
      return {
        calls: [...calls],
        actions,
        dispatched,
        prepared,
        patchURLs,
        active: active.current,
        retained: retained.current,
      };
    }
    // Until the reconcile ends: its new diff committed, or it failed and the shown one stays.
    for (
      let turn = 0;
      turn < 200 && !actions.some((type) => type === "replace-items" || type === "end-reconcile");
      turn++
    ) {
      await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    }
    return { calls, actions, dispatched, prepared, patchURLs, active: active.current, retained: retained.current };
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = savedFetch;
  }
}

const closed = (calls: [string, unknown][]) =>
  calls.filter(([method]) => method === "sessionClose").map(([, params]) => (params as Session).sessionId);

test("a failed reconcile keeps the shown diff's session active and its precomputed fingerprint", async () => {
  const result = await reconcile(async () => {
    throw new Error("the patch could not be read");
  });
  expect(result.actions).toContain("end-reconcile");
  expect(result.active?.sessionId).toBe("warm");
  expect(result.retained).toBeNull();
  // The failed replacement is closed; the shown session is not.
  expect(closed(result.calls).slice(0, 1)).toEqual(["fresh"]);
  // Only the first open set the fingerprint; the reconcile's open did not clear it.
  expect(result.prepared).toEqual(["when-the-turn-ended"]);
  expect(result.patchURLs).toEqual(["cmux-page://cmux.diff/__patch/warm/patch.diff"]);
});

test("a reconcile that commits makes its session the active one and closes the old", async () => {
  const result = await reconcile(async () => new Response(""));
  expect(result.actions).toContain("replace-items");
  expect(result.active?.sessionId).toBe("fresh");
  expect(closed(result.calls).slice(0, 1)).toEqual(["warm"]);
  expect(result.patchURLs.at(-1)).toBe("cmux-page://cmux.diff/__patch/fresh/patch.diff");
});

// Codex review of #36808 at bd9f2c5a (BLOCK P2 and follow-ups): a reconcile's renames reach the reducer
// with its items, its generated paths wait for the commit, and a page hidden mid-reconcile closes it.
// The first `a.ts` must have left the stream's pending batch (at most 96 files) before the second
// arrives, or the stream renames it in place and reports no rename.
const added = (path: string) => [
  `diff --git a/${path} b/${path}`,
  "new file mode 100644",
  "--- /dev/null",
  `+++ b/${path}`,
  "@@ -0,0 +1 @@",
  "+x",
];
const twice = [
  "diff --git a/a.ts b/a.ts",
  "deleted file mode 100644",
  "--- a/a.ts",
  "+++ /dev/null",
  "@@ -1 +0,0 @@",
  "-old",
  ...Array.from({ length: 120 }, (_, index) => added(`f${index}.ts`)).flat(),
  ...added("a.ts"),
  "",
].join("\n");

test("a reconcile hands its renames to the commit", async () => {
  const result = await reconcile(async () => new Response(twice));
  const replace = result.dispatched.find((action) => action.type === "replace-items");
  expect(replace?.renames).toEqual([{ oldId: "a.ts", newId: "a.ts?deleted" }]);
});

test("a failed reconcile leaves the shown diff's generated paths alone", async () => {
  const result = await reconcile(
    async () => {
      throw new Error("the patch could not be read");
    },
    { generatedPaths: ["gen/out.ts"] },
  );
  expect(result.actions).toContain("end-reconcile");
  const generated = result.dispatched.filter((action) => action.type === "set-generated-paths");
  expect(generated.map((action) => action.paths)).toEqual([[]]);
});

test("a reconcile that commits applies its generated paths before its items", async () => {
  const result = await reconcile(async () => new Response(""), { generatedPaths: ["gen/out.ts"] });
  const types = result.dispatched.map((action) => action.type);
  const generated = types.lastIndexOf("set-generated-paths");
  expect(result.dispatched[generated]?.paths).toEqual(["gen/out.ts"]);
  expect(generated).toBeLessThan(types.indexOf("replace-items"));
});

test("a page hidden mid-reconcile closes the replacement's session too", async () => {
  const result = await reconcile(
    () => new Promise<Response>(() => {}),
    {},
    () => void dom.window.dispatchEvent(new dom.window.Event("pagehide")),
  );
  expect(closed(result.calls).sort()).toEqual(["fresh", "warm"]);
});
