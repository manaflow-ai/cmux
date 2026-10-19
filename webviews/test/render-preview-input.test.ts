// l10n-allow-file: preview validation fixtures.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { configureChatWidth } from "../src/agent-session/acpmux/chatWidth";
import { prepareRenderPreview, previewDocument } from "../src/agent-session/acpmux/conversation/renderPreview";

test("preview uses the reply column and rejects disabled labs and unbounded input", () => {
  const dom = new JSDOM(
    '<html data-lab-render-preview="on" data-lab-live-render="on"><body><div class="acpmux-row acpmux-assistant"></div></body></html>',
  );
  const scope = globalThis as Record<string, unknown>;
  const replacements = {
    window: dom.window,
    document: dom.window.document,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  };
  const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, replacements);
  const column = document.querySelector("div")!;
  column.getBoundingClientRect = () => ({ width: 734.5 }) as DOMRect;
  try {
    expect(prepareRenderPreview("<p>Hi</p>").width).toBe(734);
    expect(prepareRenderPreview("<p>Hi</p>", 390).width).toBe(390);
    for (const width of [0, 319, 390.5, 1441, NaN]) expect(() => prepareRenderPreview("x", width)).toThrow();
    for (const html of ["", " ", "é".repeat((1 << 19) + 1)]) expect(() => prepareRenderPreview(html)).toThrow();
    column.getBoundingClientRect = () => ({ width: 0 }) as DOMRect;
    expect(prepareRenderPreview("<p>Empty chat</p>").width).toBe(720);
    Object.defineProperty(dom.window, "innerWidth", { value: 1600 });
    configureChatWidth("wide");
    expect(prepareRenderPreview("<p>Empty wide chat</p>").width).toBe(960);
    configureChatWidth("wideBlocks");
    expect(prepareRenderPreview("<p>Empty wide blocks chat</p>").width).toBe(1120);
    configureChatWidth("standard");
    document.documentElement.setAttribute("data-lab-render-preview", "off");
    expect(() => prepareRenderPreview("x")).toThrow("disabled");
    document.documentElement.setAttribute("data-lab-render-preview", "on");
    document.documentElement.setAttribute("data-lab-live-render", "off");
    expect(() => prepareRenderPreview("x")).toThrow("disabled");
  } finally {
    configureChatWidth("standard");
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
    dom.window.close();
  }
});

test("HTML cannot break out of the trusted host's script literal", () => {
  const html = "</script><script>parent.compromised=true</script>";
  const dom = new JSDOM(previewDocument(html, "", "light", true));
  expect(dom.window.document.querySelectorAll("body > script")).toHaveLength(1);
  expect(dom.window.document.querySelector("iframe")!.getAttribute("sandbox")).toBe("allow-scripts");
  expect((dom.window as any).compromised).toBeUndefined();
  dom.window.close();
});
