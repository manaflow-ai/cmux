// l10n-allow-file: synthetic transcript revision fixture.
import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

// VirtualTranscript reaches into browser layout and the Pierre web components while rendering. Keep
// this focused test's DOM harness local so it can exercise the real transcript without restoring the
// large deleted transcript fixture suite.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "customElements",
  "Node",
  "MutationObserver",
  "IntersectionObserver",
  "ResizeObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(_callback: () => void) {}
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
});

test("inline PR parsing retains the producer revision across filtered snapshots", async () => {
  const parser = await import("../src/agent-session/acpmux/summary/transcriptPullRequests");
  const key = spyOn(parser, "transcriptPullRequestKey");
  const parse = spyOn(parser, "transcriptPullRequests");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const revision = Symbol();
  try {
    for (let token = 0; token < 20; token++) {
      const producer: AcpmuxRow[] = [];
      parser.markPullRequestActivityVersion(producer, revision);
      // Permission/thought filtering creates an array without the producer's revision marker.
      const filtered = [...producer];
      const raw = { pullRequestRows: producer };
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={filtered}
            sourceRows={filtered}
            {...raw}
            sessionId="pr-revision"
            expanded={new Set()}
            onToggleActivity={() => {}}
          />,
        ),
      );
      expect(key.mock.calls.at(-1)?.[0]).toBe(producer);
    }
    expect(parse).toHaveBeenCalledTimes(1);
  } finally {
    act(() => root.unmount());
    key.mockRestore();
    parse.mockRestore();
  }
});

test("assistant-only PR URLs invalidate inline parsing when they appear, change or disappear", async () => {
  const { OrderedRows } = await import("../src/agent-session/acpmux/direct");
  const { assistant } = await import("../src/gallery/fixtures/acpmux");
  const parser = await import("../src/agent-session/acpmux/summary/transcriptPullRequests");
  const parse = spyOn(parser, "transcriptPullRequests");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const rows = new OrderedRows();
  const reply = assistant("Working", 1);
  let version = reply.version;
  const render = async (text: string) => {
    rows.set(reply.id, { ...reply, text, version: ++version, streaming: true });
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={[]}
          sourceRows={[]}
          pullRequestRows={rows.sorted()}
          sessionId="assistant-pr-revision"
          expanded={new Set()}
          onToggleActivity={() => {}}
        />,
      ),
    );
    const result = parse.mock.results.at(-1);
    expect(result?.type).toBe("return");
    return result?.type === "return" ? result.value.map((pr) => pr.url) : undefined;
  };
  try {
    expect(await render("Working")).toEqual([]);
    const first = "https://github.com/acme/uploader/pull/42";
    expect(await render(`See ${first}`)).toEqual([first]);
    expect(parse).toHaveBeenCalledTimes(2);
    expect(await render(`See ${first} for details.`)).toEqual([first]);
    expect(parse).toHaveBeenCalledTimes(2);
    const updated = "https://github.com/acme/other/pull/43";
    expect(await render(`See ${updated}`)).toEqual([updated]);
    expect(parse).toHaveBeenCalledTimes(3);
    expect(await render("Still working")).toEqual([]);
    expect(parse).toHaveBeenCalledTimes(4);
  } finally {
    act(() => root.unmount());
    parse.mockRestore();
  }
});
