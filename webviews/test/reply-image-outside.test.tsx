import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

// An image an agent names in a reply from outside the session's folders (a screenshot in /tmp)
// shows inline: the page asks the host for it, and the host reads only a raster image there. Under
// agentPane.links.outsideRoots = "text" the page never asks, and the image stays the outside card;
// a load the host refuses draws the same card.

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Element", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

test("an outside image loads unless outsideRoots is text; a refused one is the outside card", async () => {
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
  const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const shown = "/tmp/ams-shots/after-messages.png";
  const confirmed = "/tmp/ams-shots/before-messages.png";
  const textOnly = "/tmp/ams-shots/text-only.png";
  const refused = "/tmp/ams-shots/not-an-image.png";
  const loads: string[] = [];
  setChipHost(async (method, params) => {
    if (method !== "image.load") return undefined;
    const src = String(params.src);
    loads.push(src);
    return src === refused ? undefined : { src: `data:image/png;base64,${btoa(src)}` };
  });
  const flush = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const render = (src: string) =>
    act(async () => root.render(createElement(ReplyImage, { key: src, src, alt: "after", fallback: "after" })));
  const outside = { place: "outside" as const, folder: false };

  // The default policy (open) and confirm: the image draws, no card.
  for (const [src, outsideRoots] of [
    [shown, "open"],
    [confirmed, "confirm"],
  ] as const) {
    resetLinkStore();
    seedLinkStore({ paths: { [src]: outside }, policy: { outsideRoots } });
    await render(src);
    await flush();
    expect(loads).toContain(src);
    expect(rootElement.querySelectorAll("img.cv-img").length).toBe(1);
    expect(rootElement.querySelector(".cv-image-file")).toBeNull();
  }

  // outsideRoots = text: never asked, the card with its lock and no Open.
  resetLinkStore();
  seedLinkStore({ paths: { [textOnly]: outside }, policy: { outsideRoots: "text" } });
  await render(textOnly);
  await flush();
  expect(loads).not.toContain(textOnly);
  expect(rootElement.querySelector("img")).toBeNull();
  expect(rootElement.querySelector(".cv-image-file.is-outside")).not.toBeNull();
  expect(rootElement.querySelector(".cv-image-file__open")).toBeNull();

  // The host refuses (not a raster image, too large, deny-listed): the card with Open.
  resetLinkStore();
  seedLinkStore({ paths: { [refused]: outside }, policy: { outsideRoots: "open" } });
  await render(refused);
  await flush();
  expect(loads).toContain(refused);
  expect(rootElement.querySelector("img")).toBeNull();
  expect(rootElement.querySelector(".cv-image-file.is-outside")).not.toBeNull();
  expect(rootElement.querySelector(".cv-image-file__open")).not.toBeNull();

  await act(async () => root.unmount());
  setChipHost(undefined);
  resetLinkStore();
});
