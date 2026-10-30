// The image viewer's Show in Finder and Open in browser tab (cx-ncc.39): the viewer asks the host
// (AgentPaneImageCopies.swift) with the image it shows, in one request per click. Show in Finder
// also names the image's file when a reply read it from one (the host shows that file, else the
// copy); Open in browser tab sends the image. An SVG never opens in a tab, and a refusal says so.
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

type Posted = { method: string; params: Record<string, unknown> };
const posted: Posted[] = [];
// The host: refuses every request when `refuseAll`, and answers the rest.
let refuseAll = false;
(dom.window as unknown as { webkit: unknown }).webkit = {
  messageHandlers: {
    agentSession: {
      postMessage(message: { method: string; params: Record<string, unknown> }) {
        posted.push({ method: message.method, params: message.params });
        if (refuseAll) return Promise.resolve({ ok: false, error: { code: "link.path_invalid", message: "no" } });
        return Promise.resolve({ ok: true, value: true });
      },
    },
  },
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ImageViewer } = await import("../src/agent-session/acpmux/conversation/ImageViewer");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const png = "data:image/png;base64,iVBORw0KGgo=";
const svg = "data:image/svg+xml;base64,PHN2Zy8+";
const images = [
  { src: png, alt: "chart.png", path: "out/chart.png" },
  { src: png.replace("=", "A="), alt: "plain" },
  { src: svg, alt: "logo" },
];

async function show(index: number) {
  await act(async () =>
    root.render(<ImageViewer images={images} index={index} onIndex={() => undefined} onClose={() => undefined} />),
  );
}

function button(label: string): HTMLButtonElement | null {
  return dom.window.document.querySelector<HTMLButtonElement>(`.acpmux-image-viewer-action[aria-label="${label}"]`);
}

/// Clicks the action and waits until the host has its request and the viewer has its answer
/// (`done`, by default the request posted): the image goes to the host as a data URL read first.
async function click(label: string, done = (before: number) => posted.length > before) {
  const target = button(label);
  expect(target).not.toBeNull();
  const before = posted.length;
  await act(async () => target!.click());
  for (let tries = 0; tries < 200 && !done(before); tries += 1)
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  expect(done(before)).toBe(true);
  // One more task, so a duplicate request posted right after shows up in the asserts.
  await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
}

test("Show in Finder sends the image and the file it was read from, in one request", async () => {
  await show(0);
  posted.length = 0;
  await click("Show in Finder");
  expect(posted).toEqual([{ method: "image.reveal", params: { src: png, name: "chart.png", path: "out/chart.png" } }]);

  // An image no file names goes as itself.
  await show(1);
  posted.length = 0;
  await click("Show in Finder");
  expect(posted).toEqual([{ method: "image.reveal", params: { src: images[1]!.src, name: "plain" } }]);
});

test("Open in browser tab sends the image; an SVG has no such button", async () => {
  await show(0);
  posted.length = 0;
  await click("Open in browser tab");
  expect(posted).toEqual([{ method: "image.openInPane", params: { src: png, name: "chart.png" } }]);

  await show(2);
  expect(button("Show in Finder")).not.toBeNull();
  expect(button("Open in browser tab")).toBeNull();
});

test("a refused action says the image could not open", async () => {
  await show(1);
  refuseAll = true;
  await click("Open in browser tab", () => button("Couldn’t open image") !== null);
  refuseAll = false;
  expect(button("Couldn’t open image")).not.toBeNull();
  expect(button("Show in Finder")).not.toBeNull();
});
