// A refresh (Hide imports, Hide white space, a stage or revert) closes the shown session and opens a
// new one. The render effect's cleanup used to close the "pending" session too, every time. The
// host cancels whatever open is in flight on that close, so when it ran after the next run's
// sessionOpen had started, that open failed with CancellationError and the tab said "Could not
// render this diff". The cleanup now closes the pending session only while its own open is in
// flight.
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
const { pendingSessionID } = await import("../src/diff-viewer/session");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const label = createDiffViewerLabelResolver(undefined, { language: "en" });
const source = { kind: "unstaged", repoRoot: "/repo" } as const;

test("after a refresh, the old run's cleanup does not cancel the new run's open", async () => {
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
  const opened = (id: string) => ({
    type: "sessionOpened",
    value: {
      sessionId: id,
      source,
      patch: { id: `cmux-page://cmux.diff/__patch/${id}/patch.diff` },
      generatedPaths: [],
    },
  });
  const savedFetch = globalThis.fetch;
  globalThis.fetch = (async () => new Response("")) as unknown as typeof fetch;
  const config = { payload: { capabilityToken: "token", sessionSource: source } } as never;
  let refresh: () => void = () => {};

  function Viewer({ generation }: { generation: number }) {
    const active = useRef<{ sessionId: string; capabilityToken: string } | null>(null);
    const adopted = useRef(null);
    const latest = useRef({} as never);
    // App's closeActiveSession: the active session, else the pending one.
    const close = () => {
      const session = active.current;
      active.current = null;
      return transport
        .request({
          method: "sessionClose",
          params: session ?? { sessionId: pendingSessionID, capabilityToken: "token" },
        })
        .then(() => {});
    };
    refresh = () => void close();
    useRenderDiff(
      config,
      transport as never,
      label,
      () => {},
      latest,
      () => {},
      active as never,
      close,
      source as never,
      () => {},
      generation,
      adopted,
      false,
      false,
    );
    return null;
  }

  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<Viewer generation={1} />));
    await act(async () => opens.shift()!(opened("first")));
    calls.length = 0;
    // The toggle: refresh closes the shown session, then the new generation renders.
    await act(async () => {
      refresh();
      root.render(<Viewer generation={2} />);
    });
    expect(calls.map(([method]) => method)).toEqual(["sessionClose", "sessionOpen"]);
    expect(calls[0]![1]).toEqual({ sessionId: "first", capabilityToken: "token" });
    expect(calls.some(([, params]) => (params as { sessionId?: string })?.sessionId === pendingSessionID)).toBe(false);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = savedFetch;
  }
});
