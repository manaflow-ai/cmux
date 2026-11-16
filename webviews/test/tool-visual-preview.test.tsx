// l10n-allow-file: synthetic capture fixtures.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { tool } from "../src/gallery/fixtures/acpmux";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { McpCallRows } from "../src/agent-session/acpmux/conversation/McpCallRows";
import gallery from "../src/agent-session/acpmux/conversation/ToolRow.gallery";
import { toolImages } from "../src/agent-session/acpmux/toolImages";
import { ToolVisualRow } from "../src/agent-session/acpmux/conversation/ToolVisualPreview";
import { ImageViewerContext } from "../src/agent-session/acpmux/conversation/imageViewerContext";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

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

test("completed, running and MCP captures have a trailing thumbnail; closed, no image strip under them", () => {
  const cases = captureCases();
  console.info(
    `PERF capture_thumbnail_cases=${cases.filter((html) => html.includes('class="cv-tool-visual"')).length}/3`,
  );
  for (const html of cases) {
    expect(html).toContain('class="cv-tool-visual"');
    // The strip draws once the row opens (Lucas, 2026-11-11: a run of screenshots was one tall scroll).
    expect(html).not.toContain('class="cv-tool-images"');
    expect(html.match(/<img /g)).toHaveLength(1);
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

test.each(["inline", "file"])("a new %s capture keeps its preview open and updates both images", async (kind) => {
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
        <ImageViewerContext.Provider value={() => {}}>
          <ToolVisualRow sources={[source]} label="Capture">
            <span>Capture</span>
          </ToolVisualRow>
        </ImageViewerContext.Provider>,
      ),
    );
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const nextImage = `${image}AAAA`;
  const first = kind === "file" ? "/Volumes/Fixtures/capture-preview-first.png" : image;
  const next = kind === "file" ? "/Volumes/Fixtures/capture-preview-next.png" : nextImage;
  const loads: string[] = [];
  if (kind === "file") {
    resetLinkStore();
    seedLinkStore({
      paths: {
        [first]: { place: "outside", folder: false },
        [next]: { place: "outside", folder: false },
      },
      policy: { outsideRoots: "open", remoteImages: "click", clickFreeImageHosts: [] },
    });
    setChipHost(async (method, params) => {
      if (method !== "image.load") return {};
      loads.push(String(params.src));
      return { src: params.src === first ? image : nextImage };
    });
  }
  try {
    await render(first);
    const trigger = dom.window.document.querySelector<HTMLElement>(".cv-tool-visual button")!;
    expect(trigger).not.toBeNull();
    await act(async () => trigger.focus());
    expect(dom.window.document.querySelector(".cv-tool-visual-card__body img")).not.toBeNull();
    await render(next);
    if (kind === "inline") expect(dom.window.document.activeElement).toBe(trigger);
    else expect(loads).toEqual([first, next]);
    expect(dom.window.document.querySelector(".cv-tool-visual img")?.getAttribute("src")).toBe(nextImage);
    expect(dom.window.document.querySelector(".cv-tool-visual-card__body img")?.getAttribute("src")).toBe(nextImage);
  } finally {
    await act(async () => root.unmount());
    setChipHost(undefined);
    resetLinkStore();
    await settleReact();
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
