// Mermaid in agent replies (user 2026-10-19, after the Ondine evaluation: "Render Mermaid with Ondine
// (with the fallback) in the agent pane and Home chat, not as code blocks"). A finished ```mermaid
// fence draws as an SVG diagram with the markdown page's renderer (pages/markdown/diagrams.ts: Ondine,
// Mermaid 11 as fallback); a fence still streaming stays code; a source both refuse shows the source
// and why; markup in labels never reaches the page.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { join } from "node:path";
import { act } from "react";
import type { Root } from "react-dom/client";

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
  Range: dom.window.Range,
  DOMParser: dom.window.DOMParser,
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
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  delete scope.ondine;
  delete scope.mermaid;
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

// The pane's scheme handler serves this as `__lib/ondine.js`; loaded here it sets `globalThis.ondine`.
await import(join(import.meta.dir, "..", "..", "Resources", "markdown-viewer", "ondine.min.js"));
const mermaidCalls: string[] = [];
scope.mermaid = {
  initialize() {},
  async render(_id: string, source: string) {
    mermaidCalls.push(source);
    throw new Error("mermaid refused too");
  },
};

const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
const { isChart } = await import("../src/agent-session/acpmux/conversation/DiagramBlock");
// The page loads the highlighted code card once it has painted (App.tsx); so does this file. Left to
// load when the first card asks for it, the card was its plain fallback on a fast runner and the
// highlighted card on a loaded one (react-apps-check, run 39553495850).
const { loadHighlightedCode } = await import("../src/agent-session/acpmux/conversation/CodeBlock");
await loadHighlightedCode();

/// Yields to React and the renderers until `ready` holds: a loaded runner gets more yields, not a
/// longer fixed wait. Fails after 5 s with what it waited for.
async function settleUntil(ready: () => boolean, what: string) {
  const deadline = performance.now() + 5_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

/// The drawn diagram: the chart area's svg, not the bar's icons (Save is an svg too).
const diagramSvg = () => host.querySelector(".cv-diagram[data-language='mermaid'] .cv-diagram__chart svg");

async function show(source: string, streaming = false) {
  root ??= createRoot(host);
  await act(async () => root!.render(<Markdown streaming={streaming}>{source}</Markdown>));
}

/// The lines a code card in `element` shows. The highlighted card (HighlightedCode.tsx) draws them in
/// its `<diffs-container>`'s shadow root, which `textContent` leaves out. Without a worker,
/// HighlightedCode keeps the plain card; both paths must preserve the refused source.
const codeLines = (element: Element | null | undefined) => {
  const lines = element?.querySelector("diffs-container")?.shadowRoot?.querySelectorAll("[data-line]");
  return [...(lines?.length ? lines : (element?.querySelectorAll(".cv-code-plain__line") ?? []))].map(
    (line) => line.textContent ?? "",
  );
};

const FLOW = "flowchart LR\n  Start --> Check{Valid?}\n  Check -->|Yes| Done";

test("a finished mermaid fence is a diagram", () => {
  expect(isChart("mermaid", FLOW)).toBe(true);
  expect(isChart("Mermaid", FLOW)).toBe(true);
  expect(isChart("mermaid", "   ")).toBe(false);
});

test("a mermaid fence draws as SVG through Ondine, not a code block", async () => {
  await show("Here is the flow:\n\n```mermaid\n" + FLOW + "\n```\n\nDone.");
  await settleUntil(() => diagramSvg() !== null, "the diagram");
  const diagram = host.querySelector<HTMLElement>(".cv-diagram[data-language='mermaid']");
  expect(diagram).not.toBeNull();
  const svg = diagram!.querySelector(".cv-diagram__chart svg");
  expect(svg?.getAttribute("class") ?? "").toContain("ondine");
  expect(svg?.textContent).toContain("Valid?");
  expect(svg?.textContent).toContain("Done");
  expect(host.textContent).toContain("Here is the flow:");
});

test("a mermaid fence still streaming stays code", async () => {
  await show("```mermaid\nflowchart LR\n  A --> ", true);
  expect(host.querySelector(".cv-diagram")).toBeNull();
  expect(host.textContent).toContain("flowchart LR");
});

test("a source both renderers refuse shows the source and why", async () => {
  mermaidCalls.length = 0;
  await show("```mermaid\nflowchart TD\n  A --> \n```");
  const diagram = host.querySelector(".cv-diagram[data-language='mermaid']");
  // Wait for the refused source in either the highlighted or workerless code card.
  await settleUntil(() => codeLines(diagram).length > 0, "the source card's lines");
  expect(diagram?.querySelector(".cv-diagram__error")?.textContent ?? "").toContain("Parse error");
  expect(codeLines(diagram).join("\n")).toBe("flowchart TD\n  A --> ");
  expect(mermaidCalls.length).toBe(1);
});

test("markup in labels stays inert", async () => {
  await show(
    '```mermaid\nflowchart TD\n  A["<img src=x onerror=alert(1)>"] --> B["<script>alert(2)</script>"]\n  click A "javascript:alert(3)"\n```',
  );
  await settleUntil(() => diagramSvg() !== null, "the diagram");
  const diagram = host.querySelector(".cv-diagram[data-language='mermaid']")!;
  expect(diagram.querySelector(".cv-diagram__chart svg")).not.toBeNull();
  expect(diagram.querySelector("script, img, foreignObject, iframe")).toBeNull();
  for (const element of diagram.querySelectorAll("*")) {
    for (const attribute of element.attributes) {
      expect(attribute.name.toLowerCase().startsWith("on")).toBe(false);
      expect(/javascript:/i.test(attribute.value)).toBe(false);
    }
  }
});
