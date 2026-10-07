import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../model";
import { chatImages } from "./chatImages";
import { MAX_DATA_URL_LENGTH } from "./Markdown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ImageViewer, MAX_SCALE, zoomAbout } = await import("./ImageViewer");
const { Markdown } = await import("./Markdown");
const { ImageViewerContext } = await import("./imageViewerContext");

const png = (tag: string) => `data:image/png;base64,${tag}AAAA`;
const reply = (id: string, text: string): AcpmuxRow => ({ id, version: 1, at: 0, kind: "assistant", text });

test("the chat's images are its replies' inline images, oldest first, each once, never code", () => {
  const rows: AcpmuxRow[] = [
    { id: "u", version: 1, at: 0, kind: "user", text: `![mine](${png("U")})` },
    reply("a", `Before ![Light](${png("A")}) and ![Dark](${png("B")}).`),
    reply("b", `Again ![Light](${png("A")})\n\n\`\`\`md\n![fenced](${png("C")})\n\`\`\`\n\n\`![span](${png("D")})\``),
    reply("c", `![huge](data:image/png;base64,${"A".repeat(MAX_DATA_URL_LENGTH)}) ![web](https://example.com/a.png)`),
    reply("d", `![Chart](data:image/svg+xml;base64,PHN2Zz4=)`),
  ];
  expect(chatImages(rows)).toEqual([
    { src: png("A"), alt: "Light" },
    { src: png("B"), alt: "Dark" },
    { src: "data:image/svg+xml;base64,PHN2Zz4=", alt: "Chart" },
  ]);
});

test("zooming keeps the point under the pointer still, stays in range and recenters when fitted", () => {
  const zoomed = zoomAbout({ scale: 1, x: 0, y: 0 }, 2, { x: 100, y: 50 });
  expect(zoomed).toEqual({ scale: 2, x: -100, y: -50 });
  // The image pixel under (100, 50) is (100 - x) / scale before and after.
  expect((100 - zoomed.x) / zoomed.scale).toBe(100);
  expect(zoomAbout(zoomed, 100, { x: 0, y: 0 }).scale).toBe(MAX_SCALE);
  expect(zoomAbout(zoomed, 0.5, { x: 30, y: 30 })).toEqual({ scale: 1, x: 0, y: 0 });
});

async function mount(element: ReturnType<typeof createElement>) {
  const container = dom.window.document.body.appendChild(dom.window.document.createElement("div"));
  const root = createRoot(container);
  await act(async () => root.render(element));
  return {
    container,
    unmount: () => act(async () => root.unmount()).then(() => container.remove()),
  };
}

const key = (target: Element, name: string) =>
  act(async () => {
    target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true }));
  });

test("a reply image opens the viewer on its source; without a viewer it stays a plain image", async () => {
  const opened: string[] = [];
  const text = `![Light](${png("A")})`;
  const withViewer = await mount(
    createElement(
      ImageViewerContext.Provider,
      { value: (src: string) => opened.push(src) },
      createElement(Markdown, null, text),
    ),
  );
  const button = withViewer.container.querySelector<HTMLButtonElement>("button.cv-img-open")!;
  expect(button.querySelector("img.cv-img")?.getAttribute("alt")).toBe("Light");
  await act(async () => button.click());
  expect(opened).toEqual([png("A")]);
  await withViewer.unmount();

  const plain = await mount(createElement(Markdown, null, text));
  expect(plain.container.querySelector("button")).toBeNull();
  expect(plain.container.querySelector("img.cv-img")).not.toBeNull();
  await plain.unmount();
});

test("the viewer names the image and its place, steps with the arrows and closes on Escape", async () => {
  const images = [
    { src: png("A"), alt: "Light" },
    { src: png("B"), alt: "Dark" },
    { src: png("C"), alt: "Contrast" },
  ];
  const steps: number[] = [];
  let closed = 0;
  const viewer = (index: number) =>
    createElement(ImageViewer, { images, index, onIndex: (next: number) => steps.push(next), onClose: () => closed++ });
  const { container, unmount } = await mount(viewer(0));
  const layer = container.querySelector(".acpmux-image-viewer")!;
  expect(layer.getAttribute("role")).toBe("dialog");
  expect(container.querySelector(".acpmux-image-viewer-title")?.textContent).toBe("Light");
  expect(container.querySelector(".acpmux-image-viewer-count")?.textContent).toBe("1 of 3");
  expect(container.querySelector(".acpmux-image-viewer-image")?.getAttribute("src")).toBe(png("A"));
  await key(layer, "ArrowLeft");
  await key(layer, "ArrowRight");
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-image-viewer-step.is-next")!.click());
  expect(steps).toEqual([2, 1, 1]);
  await key(layer, "Escape");
  expect(closed).toBe(1);
  await unmount();
});

test("one image has no arrows or place, and + zooms it in place", async () => {
  const { container, unmount } = await mount(
    createElement(ImageViewer, {
      images: [{ src: png("A"), alt: "" }],
      index: 0,
      onIndex: () => {},
      onClose: () => {},
    }),
  );
  expect(container.querySelector(".acpmux-image-viewer-step")).toBeNull();
  expect(container.querySelector(".acpmux-image-viewer-count")).toBeNull();
  const layer = container.querySelector(".acpmux-image-viewer")!;
  expect(layer.getAttribute("aria-label")).toBe("Image");
  await key(layer, "+");
  const image = container.querySelector<HTMLElement>(".acpmux-image-viewer-image")!;
  expect(image.style.transform).toBe("translate(0px, 0px) scale(2)");
  expect(container.querySelector(".acpmux-image-viewer-stage")?.classList.contains("is-zoomed")).toBe(true);
  await key(layer, "0");
  expect(image.style.transform).toBe("translate(0px, 0px) scale(1)");
  await unmount();
});
