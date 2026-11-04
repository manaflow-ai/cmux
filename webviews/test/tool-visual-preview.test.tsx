// l10n-allow-file: synthetic capture fixtures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { tool } from "../src/gallery/fixtures/acpmux";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { McpCallRows } from "../src/agent-session/acpmux/conversation/McpCallRows";
import gallery from "../src/agent-session/acpmux/conversation/ToolRow.gallery";
import { toolImages } from "../src/agent-session/acpmux/toolImages";
import { ToolVisualRow } from "../src/agent-session/acpmux/conversation/ToolVisualPreview";
import { JSDOM } from "jsdom";

const image = "data:image/png;base64,iVBORw0KGgo=";
const envelope = JSON.stringify([{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }]);

test("the running gallery uses a supported partial capture envelope", () => {
  const items = gallery.variants.running!.snapshot.rows.flatMap((row) => row.items ?? []);
  const running = items.find((item) => item.tool?.status === "in_progress")?.tool;
  expect(running).toBeDefined();
  expect(toolImages(running!)).toHaveLength(1);
});

export const captureCases = () => [
  renderToStaticMarkup(<ToolRow item={tool("Capture page", "fetch", "completed", { images: [image] })} />),
  renderToStaticMarkup(<ToolRow item={tool("Capture page", "fetch", "in_progress", { output: envelope })} />),
  renderToStaticMarkup(
    <McpCallRows
      items={[tool("mcp__browser__capture", "other", "completed", { output: envelope })]}
      disclosureKey="capture"
    />,
  ),
];

test("completed, running and MCP captures have a trailing thumbnail without removing the image strip", () => {
  const cases = captureCases();
  console.info(
    `PERF capture_thumbnail_cases=${cases.filter((html) => html.includes('class="cv-tool-visual"')).length}/3`,
  );
  for (const html of cases) {
    expect(html).toContain('class="cv-tool-visual"');
    expect(html).toContain('class="cv-tool-images"');
    expect(html.match(/<img /g)).toHaveLength(2);
    expect(html).not.toContain('class="cv-tool-visual-card__body"');
  }
});

test("plain tool rows retain their markup without a visual wrapper", () => {
  const html = renderToStaticMarkup(<ToolRow item={tool("Read README", "read", "completed", { output: "Read it" })} />);
  expect(html).not.toContain("cv-tool-with-visual");
});

test("inline audio is never treated as a screenshot", () => {
  const audio = JSON.stringify([{ type: "audio", mimeType: "audio/wav", data: "AAAA" }]);
  const html = renderToStaticMarkup(
    <McpCallRows items={[tool("mcp__audio__speak", "other", "completed", { output: audio })]} disclosureKey="audio" />,
  );
  expect(html).not.toContain("cv-tool-visual");
});

test("a new capture keeps the focused preview open and updates both images", async () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (source: string) =>
    act(async () =>
      root.render(
        <ToolVisualRow sources={[source]} label="Capture">
          <span>Capture</span>
        </ToolVisualRow>,
      ),
    );
  try {
    await render(image);
    const trigger = dom.window.document.querySelector<HTMLElement>(".cv-tool-visual button")!;
    expect(trigger).not.toBeNull();
    await act(async () => trigger.focus());
    expect(dom.window.document.querySelector(".cv-tool-visual-card__body img")).not.toBeNull();
    const next = `${image}AAAA`;
    await render(next);
    expect(dom.window.document.activeElement).toBe(trigger);
    expect(dom.window.document.querySelector(".cv-tool-visual img")?.getAttribute("src")).toBe(next);
    expect(dom.window.document.querySelector(".cv-tool-visual-card__body img")?.getAttribute("src")).toBe(next);
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
