// A reply's image thumbnail (chips/ReplyImage.tsx OpenableImage) keeps the fixed frame (chips.css
// .cv-thumb, 16:10) until its image loads, so a lazy or slow image holds its place in the transcript;
// once loaded it takes the image's own shape (.cv-thumb--sized). The same holds where the pane has no
// image viewer (a guest or read-only page), which draws the thumbnail as a plain span.
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

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { OpenableImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
const { ImageViewerContext } = await import("../src/agent-session/acpmux/conversation/imageViewerContext");

afterAll(() => {
  for (const [key, had, value] of saved)
    if (had) scope[key] = value;
    else delete scope[key];
  dom.window.close();
});

const host = dom.window.document.getElementById("root")!;

/// Renders a thumbnail of `src`, then loads its image at `width`×`height`, and answers the frame before
/// and after.
async function frames(viewer: boolean, width: number, height: number, src = "data:image/png;base64,AAAA") {
  const root = createRoot(host);
  const thumb = <OpenableImage src={src} alt="" thumb />;
  await act(async () =>
    root.render(viewer ? <ImageViewerContext.Provider value={() => {}}>{thumb}</ImageViewerContext.Provider> : thumb),
  );
  const frame = () => host.querySelector<HTMLElement>(".cv-thumb")!;
  const before = { className: frame().className, width: frame().style.getPropertyValue("--thumb-w") };
  const img = host.querySelector("img")!;
  Object.defineProperty(img, "naturalWidth", { value: width });
  Object.defineProperty(img, "naturalHeight", { value: height });
  await act(async () => void img.dispatchEvent(new dom.window.Event("load")));
  const after = {
    className: frame().className,
    width: frame().style.getPropertyValue("--thumb-w"),
    height: frame().style.getPropertyValue("--thumb-h"),
  };
  await act(async () => root.unmount());
  return { before, after };
}

for (const viewer of [true, false])
  test(`a reply thumbnail keeps the fixed frame until its image loads (${viewer ? "with" : "without"} a viewer)`, async () => {
    // Each its own source: the pane remembers the size a source drew at, and reserves it next time.
    const { before, after } = await frames(viewer, 390, 844, `data:image/png;base64,${viewer ? "AAAA" : "AAAB"}`);
    expect(before.className).toBe("cv-thumb");
    expect(before.width).toBe("");
    expect(after.className).toBe("cv-thumb cv-thumb--sized");
    expect([after.width, after.height]).toEqual(["390", "844"]);
  });

// A data URL whose header names its size draws its own shape from the first paint: nothing moves when
// it loads (the image viewer's gallery replies, an agent's SVG chart).
const svg = (width: number, height: number) =>
  `data:image/svg+xml;base64,${btoa(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"></svg>`)}`;
test("a thumbnail whose header names its size has its own shape before it loads", async () => {
  const { before, after } = await frames(true, 640, 400, svg(640, 400));
  expect(before.className).toBe("cv-thumb cv-thumb--sized");
  expect(before.width).toBe("640");
  expect(after.className).toBe("cv-thumb cv-thumb--sized");
  expect([after.width, after.height]).toEqual(["640", "400"]);
});
