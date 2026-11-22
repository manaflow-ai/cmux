import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// Reply text and shell output are not trusted, so the card never loads a loopback page by itself:
// the frame appears only after the reader clicks "Load preview".
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "location", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  location: dom.window.location,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { renderToStaticMarkup } = await import("react-dom/server");
const { PreviewCard } = await import("./PreviewCard");

test("a card from reply text or shell output renders no frame and loads nothing", () => {
  const html = renderToStaticMarkup(
    createElement(PreviewCard, { url: "http://localhost:5173/admin?tab=1", onOpen: () => {} }),
  );
  expect(html).not.toContain("<iframe");
  expect(html).not.toContain('src="http://localhost:5173');
  expect(html).toContain(">Load preview</button>");
});

// The click is the reader's consent: it loads the address the card shows (hqacp-v4 loaded "/", a
// directory listing, for /preview.html), on the same loopback host and port, still without forms.
test("the frame loads the address the card shows only after a click, without forms", async () => {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  const opened: string[] = [];
  await act(async () =>
    root.render(
      createElement(PreviewCard, {
        url: "http://127.0.0.1:3000/preview.html?tab=1#top",
        onOpen: (u) => opened.push(u),
      }),
    ),
  );
  expect(container.querySelector("iframe")).toBeNull();
  const load = container.querySelector<HTMLButtonElement>(".acpmux-turn-preview-load")!;
  expect(load.textContent).toBe("Load preview");
  await act(async () => load.click());
  const frame = container.querySelector("iframe")!;
  expect(container.querySelector(".acpmux-turn-preview-address")!.textContent).toBe(
    "127.0.0.1:3000/preview.html?tab=1",
  );
  expect(frame.getAttribute("src")).toBe("http://127.0.0.1:3000/preview.html?tab=1");
  expect(frame.getAttribute("sandbox")).toBe("allow-scripts allow-same-origin");
  // Loading is not opening: the host was asked for nothing.
  expect(opened).toEqual([]);
  await act(async () => root.unmount());
});
