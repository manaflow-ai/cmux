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
// The window's globals the pane and ui/Dialog (Base UI) read.
const NAMES = [
  "window",
  "document",
  "navigator",
  "Element",
  "HTMLElement",
  "Node",
  "Event",
  "KeyboardEvent",
  "MouseEvent",
  "MutationObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = Object.fromEntries(NAMES.map((key) => [key, globals[key]]));
for (const name of NAMES) globals[name] = (dom.window as unknown as Record<string, unknown>)[name];
globals.window = dom.window;
globals.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
globals.IS_REACT_ACT_ENVIRONMENT = true;
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { renderToStaticMarkup } = await import("react-dom/server");
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

test("the chat's images are exactly the images the reply draws", () => {
  const svg = (tag: string) => `data:image/svg+xml;base64,${tag}`;
  const rows: AcpmuxRow[] = [
    // An image on a fence's later line is code, and the image after the fence is not.
    reply("a", `Example:\n\n\`\`\`md\n# heading\n![fenced](${png("C")})\n\`\`\`\n![after](${png("E")})`),
    // A lone backtick in one paragraph does not pair with code in a later one.
    reply("b", `Press the \` key.\n\n![shot](${png("F")})\n\nRun \`ls\`.`),
    // A target with one level of parentheses, as Markdown.tsx reads it, and an image in bold.
    reply("c", `![chart](${svg("PHN2Zz4=(2)")}) and **![bold](${png("G")})**`),
    // Notes draw under the reply in reference order; a data URL's scheme is any case.
    reply("d", `Intro[^1]\n\n[^1]: ![note](${png("H")})\n\n![body](${png("I")})`),
    reply("e", "![up](data:IMAGE/png;base64,J)"),
  ];
  const drawn = (text: string) => {
    const html = renderToStaticMarkup(createElement(Markdown, null, text));
    return [...html.matchAll(/<img class="cv-img" src="([^"]+)" alt="([^"]*)"/g)].map(([, src, alt]) => ({
      src: src!.replaceAll("&amp;", "&"),
      alt: alt!,
    }));
  };
  expect(chatImages(rows)).toEqual(rows.flatMap((row) => drawn(row.text!)));
  expect(chatImages(rows).map((image) => image.alt)).toEqual(["after", "shot", "chart", "bold", "body", "note", "up"]);
});

test("a long data URL image is listed, and images past the reply's 8 MB budget are not, as the reply draws them", () => {
  const sized = (tag: string, length: number) => png(tag + "A".repeat(length));
  const long = sized("L", 10_000);
  const big = ["P", "Q", "R", "S", "T"].map((tag) => sized(tag, MAX_DATA_URL_LENGTH - 100_000));
  const rows: AcpmuxRow[] = [
    reply("a", `A long one ![long](${long}) and **![long bold](${sized("M", 10_000)})**`),
    reply("b", big.map((src, index) => `![big ${index}](${src})`).join("\n\n")),
  ];
  const drawn = (text: string) =>
    [
      ...renderToStaticMarkup(createElement(Markdown, null, text)).matchAll(
        /<img class="cv-img" src="([^"]+)" alt="([^"]*)"/g,
      ),
    ].map(([, src, alt]) => ({ src: src!, alt: alt! }));
  expect(chatImages(rows)).toEqual(rows.flatMap((row) => drawn(row.text!)));
  expect(chatImages(rows).map((image) => image.alt)).toEqual(["long", "long bold", "big 0", "big 1", "big 2", "big 3"]);
  expect(chatImages(rows)[0]!.src).toBe(long);
});

test("zooming keeps the point under the pointer still, stays in range and recenters when fitted", () => {
  const zoomed = zoomAbout({ scale: 1, x: 0, y: 0 }, 2, { x: 100, y: 50 });
  expect(zoomed).toEqual({ scale: 2, x: -100, y: -50 });
  // The image pixel under (100, 50) is (100 - x) / scale before and after.
  expect((100 - zoomed.x) / zoomed.scale).toBe(100);
  expect(zoomAbout(zoomed, 100, { x: 0, y: 0 }).scale).toBe(MAX_SCALE);
  expect(zoomAbout(zoomed, 0.5, { x: 30, y: 30 })).toEqual({ scale: 1, x: 0, y: 0 });
});

// The viewer is a portaled dialog (ui/Dialog): it draws under the document's body, not the mount.
const doc = () => dom.window.document;

/// Waits, a frame at a time, until `ready` holds: Base UI mounts its portal and moves focus a frame
/// after the render.
async function until(ready: () => unknown) {
  for (let frame = 0; frame < 60 && !ready(); frame++)
    await act(() => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve())));
  expect(Boolean(ready())).toBe(true);
}

async function mount(element: ReturnType<typeof createElement>) {
  const container = dom.window.document.body.appendChild(dom.window.document.createElement("div"));
  const root = createRoot(container);
  await act(async () => root.render(element));
  return {
    container,
    // A portaled dialog (Base UI) cleans up a frame after the unmount; the next test starts clean.
    unmount: async () => {
      await act(async () => root.unmount());
      container.remove();
      await until(() => !doc().querySelector("[data-base-ui-portal], [data-base-ui-inert]"));
    },
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
  const { unmount } = await mount(viewer(0));
  await until(() => doc().querySelector(".acpmux-image-viewer"));
  const layer = doc().querySelector(".acpmux-image-viewer")!;
  expect(layer.getAttribute("role")).toBe("dialog");
  expect(layer.getAttribute("aria-label")).toBe("Light");
  expect(doc().querySelector(".acpmux-image-viewer-title")?.textContent).toBe("Light");
  expect(doc().querySelector(".acpmux-image-viewer-count")?.textContent).toBe("1 of 3");
  expect(doc().querySelector(".acpmux-image-viewer-image")?.getAttribute("src")).toBe(png("A"));
  const body = doc().querySelector(".acpmux-image-viewer-body")!;
  await key(body, "ArrowLeft");
  await key(body, "ArrowRight");
  await act(async () => doc().querySelector<HTMLButtonElement>(".acpmux-image-viewer-step.is-next")!.click());
  expect(steps).toEqual([2, 1, 1]);
  await key(doc().activeElement ?? body, "Escape");
  expect(closed).toBe(1);
  await unmount();
});

test("the viewer is modal and starts on Close, so Tab stays inside it", async () => {
  const { unmount } = await mount(
    createElement(ImageViewer, {
      images: [{ src: png("A"), alt: "Light" }],
      index: 0,
      onIndex: () => {},
      onClose: () => {},
    }),
  );
  await until(() => doc().querySelector(".acpmux-image-viewer"));
  const layer = doc().querySelector(".acpmux-image-viewer")!;
  expect(layer.getAttribute("role")).toBe("dialog");
  // ui/Dialog (Base UI) is modal: the page behind is hidden and inert, so focus cannot leave.
  expect(doc().getElementById("root")?.getAttribute("aria-hidden")).toBe("true");
  await until(() => doc().activeElement?.getAttribute("aria-label") === "Close");
  await unmount();
});

test("an image the list does not know still opens under its own name", async () => {
  const opened: [string, string][] = [];
  const text = `![Light](${png("A")})`;
  const { container, unmount } = await mount(
    createElement(
      ImageViewerContext.Provider,
      { value: (src: string, alt: string) => opened.push([src, alt]) },
      createElement(Markdown, null, text),
    ),
  );
  await act(async () => container.querySelector<HTMLButtonElement>("button.cv-img-open")!.click());
  expect(opened).toEqual([[png("A"), "Light"]]);
  await unmount();
});

test("one image has no arrows or place, and + zooms it in place", async () => {
  const { unmount } = await mount(
    createElement(ImageViewer, {
      images: [{ src: png("A"), alt: "" }],
      index: 0,
      onIndex: () => {},
      onClose: () => {},
    }),
  );
  await until(() => doc().querySelector(".acpmux-image-viewer"));
  expect(doc().querySelector(".acpmux-image-viewer-step")).toBeNull();
  expect(doc().querySelector(".acpmux-image-viewer-count")).toBeNull();
  expect(doc().querySelector(".acpmux-image-viewer")!.getAttribute("aria-label")).toBe("Image");
  const body = doc().querySelector(".acpmux-image-viewer-body")!;
  await key(body, "+");
  const image = doc().querySelector<HTMLElement>(".acpmux-image-viewer-image")!;
  expect(image.style.transform).toBe("translate(0px, 0px) scale(2)");
  expect(doc().querySelector(".acpmux-image-viewer-stage")?.classList.contains("is-zoomed")).toBe(true);
  await key(body, "0");
  expect(image.style.transform).toBe("translate(0px, 0px) scale(1)");
  await unmount();
});

test("the image keys work with focus on the viewer itself", async () => {
  const { unmount } = await mount(
    createElement(ImageViewer, {
      images: [{ src: png("A"), alt: "Light" }],
      index: 0,
      onIndex: () => {},
      onClose: () => {},
    }),
  );
  await until(() => doc().querySelector(".acpmux-image-viewer-stage"));
  // A press on the image or a button focuses the dialog itself (WebKit does not focus buttons).
  const layer = doc().querySelector<HTMLElement>(".acpmux-image-viewer")!;
  await act(async () => layer.focus());
  await key(layer, "+");
  const image = doc().querySelector<HTMLElement>(".acpmux-image-viewer-image")!;
  expect(image.style.transform).toBe("translate(0px, 0px) scale(2)");
  await unmount();
});

test("Control-scroll on the stage zooms the image, and the pane never scrolls behind", async () => {
  const { unmount } = await mount(
    createElement(ImageViewer, {
      images: [{ src: png("A"), alt: "Light" }],
      index: 0,
      onIndex: () => {},
      onClose: () => {},
    }),
  );
  await until(() => doc().querySelector(".acpmux-image-viewer-stage"));
  const image = doc().querySelector<HTMLElement>(".acpmux-image-viewer-image")!;
  const wheel = new dom.window.WheelEvent("wheel", { deltaY: -100, ctrlKey: true, bubbles: true, cancelable: true });
  await act(async () => doc().querySelector(".acpmux-image-viewer-stage")!.dispatchEvent(wheel));
  expect(wheel.defaultPrevented).toBe(true);
  expect(image.style.transform).not.toBe("translate(0px, 0px) scale(1)");
  await unmount();
});

test("a copy that finishes after the viewer moved on labels only the image it copied", async () => {
  // A copy the test finishes by hand; the image never loads, as in jsdom.
  let finish = () => {};
  const clipboard = Object.getOwnPropertyDescriptor(dom.window.navigator, "clipboard");
  Object.defineProperty(dom.window.navigator, "clipboard", {
    configurable: true,
    value: { write: () => new Promise<void>((resolve) => (finish = resolve)) },
  });
  const savedItem = globals.ClipboardItem;
  const savedImage = globals.Image;
  globals.ClipboardItem = class {};
  globals.Image = class {};
  const images = [
    { src: png("A"), alt: "Light" },
    { src: png("B"), alt: "Dark" },
  ];
  const container = dom.window.document.body.appendChild(dom.window.document.createElement("div"));
  const root = createRoot(container);
  const show = (index: number) =>
    act(async () => root.render(createElement(ImageViewer, { images, index, onIndex: () => {}, onClose: () => {} })));
  await show(0);
  await until(() => doc().querySelector(".acpmux-image-viewer"));
  const copy = () => doc().querySelector<HTMLButtonElement>(".acpmux-image-viewer-action")!;
  expect(copy().getAttribute("aria-label")).toBe("Copy image");
  await act(async () => copy().click());
  await show(1);
  await act(async () => finish());
  expect(doc().querySelector(".acpmux-image-viewer-image")?.getAttribute("src")).toBe(png("B"));
  expect(copy().getAttribute("aria-label")).toBe("Copy image");
  await act(async () => root.unmount());
  container.remove();
  await until(() => !doc().querySelector("[data-base-ui-portal], [data-base-ui-inert]"));
  globals.ClipboardItem = savedItem;
  globals.Image = savedImage;
  if (clipboard) Object.defineProperty(dom.window.navigator, "clipboard", clipboard);
  else delete (dom.window.navigator as unknown as Record<string, unknown>).clipboard;
});
