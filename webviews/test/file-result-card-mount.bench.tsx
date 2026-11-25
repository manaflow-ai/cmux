// l10n-allow-file: bench fixtures.
// Mount cost of an opened file search card (#43915): `bun test/file-result-card-mount.bench.tsx`.
// One harness for every row count: React mounts the card in jsdom (no layout, so this is the DOM and
// React cost of the rows, not paint), median of RUNS mounts each.
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot } from "react-dom/client";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Node: dom.window.Node,
  NodeFilter: dom.window.NodeFilter,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  MutationObserver: dom.window.MutationObserver,
  customElements: dom.window.customElements,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
const { resetTranscriptDisclosure } =
  await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");
const { HARNESS_CALLS } = await import("../src/agent-session/acpmux/toolNamesFixture");

const RUNS = 7;
const ROWS = [16, 500, 2_000, 5_000];
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)]!;

for (const rows of ROWS) {
  const output = Array.from({ length: rows }, (_, index) => `/w/src/big.ts:${index + 1}:match ${index + 1}`).join("\n");
  const item = {
    kind: "tool" as const,
    text: "search",
    tool: { ...HARNESS_CALLS.claude.search, output },
  };
  const times: number[] = [];
  let mounted = 0;
  for (let run = 0; run < RUNS + 1; run++) {
    const container = dom.window.document.createElement("div");
    dom.window.document.body.append(container);
    const root = createRoot(container);
    await act(async () => root.render(<ToolRow item={item} />));
    const toggle = container.querySelector<HTMLElement>("button.cv-tool")!;
    const start = performance.now();
    await act(async () => toggle.click());
    await act(async () => {});
    const took = performance.now() - start;
    mounted = container.querySelectorAll(".cv-filematches__line").length;
    if (run > 0) times.push(took); // the first mount warms the module graph
    await act(async () => root.unmount());
    container.remove();
    resetTranscriptDisclosure(); // the open state outlives a mount
  }
  console.log(`${rows} matches: ${mounted} rows mounted, mount ${median(times).toFixed(0)} ms (median of ${RUNS})`);
}
dom.window.close();
process.exit(0);
