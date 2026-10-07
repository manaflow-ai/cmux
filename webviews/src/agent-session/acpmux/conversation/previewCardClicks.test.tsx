import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// A dev-server pane: the page itself is on loopback.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://127.0.0.1:4176/",
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
const { PreviewCard } = await import("./PreviewCard");

async function render(url: string, opened: string[]) {
  const container = dom.window.document.getElementById("root")!;
  const root = createRoot(container);
  await act(async () => root.render(createElement(PreviewCard, { url, onOpen: (target) => opened.push(target) })));
  return { container, unmount: () => act(async () => root.unmount()) };
}

test("the thumbnail opens the page it shows; Open in tab opens the address the head names", async () => {
  const opened: string[] = [];
  const { container, unmount } = await render("http://localhost:5173/admin?tab=1", opened);
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-turn-preview-load")!.click());
  const frame = container.querySelector("iframe")!;
  expect(frame.getAttribute("src")).toBe("http://localhost:5173/admin?tab=1");
  expect(frame.getAttribute("referrerpolicy")).toBe("no-referrer");
  expect(frame.getAttribute("tabindex")).toBe("-1");
  await act(async () => container.querySelector<HTMLElement>(".acpmux-turn-preview-frame")!.click());
  await act(async () => container.querySelector<HTMLButtonElement>("button")!.click());
  expect(opened).toEqual(["http://localhost:5173/admin?tab=1", "http://localhost:5173/admin?tab=1"]);
  await unmount();
});

test("a page on the pane's own origin gets no frame, only its address and Open in tab", async () => {
  const { container, unmount } = await render("http://127.0.0.1:4176/", []);
  expect(container.querySelector("iframe")).toBeNull();
  expect(container.querySelector(".acpmux-turn-preview-load")).toBeNull();
  expect(container.querySelector("button")?.textContent).toBe("Open in tab");
  await unmount();
});
