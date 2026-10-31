// The user, 2026-10-21: "i need to be able to drag it out to other apps too". A drag that starts
// on an image or a file chip in an agent chat is handed to the host (the page's own drag is
// cancelled), which drags the real file out: the image as a `data:` URL with its name
// (`image.drag`), a file chip by its path (`file.drag`). A drag on anything else stays the page's.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  HTMLImageElement: dom.window.HTMLImageElement,
  HTMLAnchorElement: dom.window.HTMLAnchorElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Event: dom.window.Event,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { installDragOut } = await import("../src/agent-session/acpmux/conversation/dragOut");

const png = "data:image/png;base64,iVBORw0KGgo=";
const doc = dom.window.document;
doc.getElementById("root")!.innerHTML = `
  <div data-row-id="reply">
    <p id="words">Here is the chart.</p>
    <button data-open-image><img id="picture" src="${png}" alt="chart"></button>
    <button class="cv-chip is-path" data-path="/work/demo.mp4" draggable="true"><span id="chip">demo.mp4</span></button>
  </div>`;
const posted: { method: string; params: Record<string, unknown> }[] = [];
installDragOut(doc, async (method, params) => void posted.push({ method, params }));
const drag = (id: string) => {
  const event = new dom.window.Event("dragstart", { bubbles: true, cancelable: true });
  doc.getElementById(id)!.dispatchEvent(event);
  return event;
};
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("a drag on an image goes to the host as the image", async () => {
  posted.length = 0;
  expect(drag("picture").defaultPrevented).toBe(true);
  await settle();
  expect(posted).toEqual([{ method: "image.drag", params: { src: png, name: "chart" } }]);
});

test("a drag on a file chip goes to the host as its path", async () => {
  posted.length = 0;
  expect(drag("chip").defaultPrevented).toBe(true);
  await settle();
  expect(posted).toEqual([{ method: "file.drag", params: { path: "/work/demo.mp4" } }]);
});

test("a drag on words stays the page's", async () => {
  posted.length = 0;
  expect(drag("words").defaultPrevented).toBe(false);
  await settle();
  expect(posted).toEqual([]);
});
