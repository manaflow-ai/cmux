// The user, 2026-10-21: "in chief i need to be able to right click any image/video etc 'copy'".
// A right-click on an image in an agent chat reports it (`image`, and `openImage` when a click
// opens it) with the menu; the menu's Copy Image, Save Image As…, Quick Look and Show in Finder
// then hand the host that image as a `data:` URL with its name (and, for Show in Finder, the file
// a reply read it from). A right-click elsewhere reports no image and those actions send nothing.
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
  MouseEvent: dom.window.MouseEvent,
};
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Posted = { method: string; params: Record<string, unknown> };
const posted: Posted[] = [];
(dom.window as unknown as { webkit: unknown }).webkit = {
  messageHandlers: {
    agentSession: {
      postMessage(message: Posted) {
        posted.push({ method: message.method, params: message.params });
        return Promise.resolve({ ok: true, value: true });
      },
    },
  },
};

const { installMessageMenuReporter } = await import("../src/agent-session/acpmux/conversation/messageMenu");
const { actOnReportedImage } = await import("../src/agent-session/acpmux/conversation/imageMenuActions");

const png = "data:image/png;base64,iVBORw0KGgo=";
const doc = dom.window.document;
doc.getElementById("root")!.innerHTML = `
  <div data-row-id="reply">
    <p id="words">Here is the chart.</p>
    <button data-open-image data-image-path="/work/chart.png"><img id="reply-image" src="${png}" alt="chart"></button>
  </div>
  <div data-row-id="prompt"><img id="sent-image" src="${png}" alt="Image 4 × 3"></div>`;
const reports: unknown[] = [];
installMessageMenuReporter(doc, () => ({ postMessage: (body: unknown) => reports.push(body) }));
const rightClick = (id: string) =>
  doc.getElementById(id)!.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }));

test("a right-click on a reply's image reports it, and Copy Image sends it to the host", async () => {
  posted.length = 0;
  rightClick("reply-image");
  expect(reports.at(-1)).toMatchObject({ openImage: true, image: true });
  expect(await actOnReportedImage("image.copy")).toBe(true);
  expect(posted).toEqual([{ method: "image.copy", params: { src: png, name: "chart" } }]);
});

test("Show in Finder names the file the reply read the image from", async () => {
  posted.length = 0;
  rightClick("reply-image");
  expect(await actOnReportedImage("image.reveal")).toBe(true);
  expect(posted).toEqual([{ method: "image.reveal", params: { src: png, name: "chart", path: "/work/chart.png" } }]);
});

test("an image I sent is reported too, for Save Image As… and Quick Look", async () => {
  posted.length = 0;
  rightClick("sent-image");
  expect(reports.at(-1)).toMatchObject({ image: true });
  expect(await actOnReportedImage("image.save")).toBe(true);
  rightClick("sent-image");
  expect(await actOnReportedImage("image.quickLook")).toBe(true);
  expect(posted.map((p) => p.method)).toEqual(["image.save", "image.quickLook"]);
  expect(posted[0]!.params).toEqual({ src: png, name: "Image 4 × 3" });
});

test("a right-click on words reports no image, and the image actions send nothing", async () => {
  posted.length = 0;
  rightClick("words");
  expect((reports.at(-1) as Record<string, unknown> | null)?.image).toBeUndefined();
  expect(await actOnReportedImage("image.copy")).toBe(false);
  expect(posted).toEqual([]);
});
