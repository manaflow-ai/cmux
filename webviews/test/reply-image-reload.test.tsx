import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { IMAGE_CACHE_MAX_ENTRIES } from "../src/agent-session/acpmux/chips/imageCache";

// Reply images keep a bounded cache of what loaded on their own. An image the reader loaded with
// "Load image" must still draw when it comes back into view: loading it again would need another
// click, since the host spends one gesture on each click-policy load.

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

test("a clicked image survives the automatic cache filling up; an evicted automatic one loads again", async () => {
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
  const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const loads: string[] = [];
  setChipHost(async (method, params) => {
    if (method !== "image.load") return undefined;
    const src = String(params.src);
    loads.push(src);
    return { src: `data:image/png;base64,${btoa(src)}` };
  });
  const flush = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const images = (srcs: string[]) =>
    act(async () => {
      root.render(
        createElement(
          "div",
          null,
          srcs.map((src) => createElement(ReplyImage, { key: src, src, alt: src, fallback: "fallback" })),
        ),
      );
    });
  const clicked = "https://images.example.com/clicked.png";
  const autos = Array.from(
    { length: IMAGE_CACHE_MAX_ENTRIES + 2 },
    (_, i) => `https://images.example.com/auto-${i}.png`,
  );

  resetLinkStore();
  seedLinkStore({ policy: { remoteImages: "click" } });
  await images([clicked]);
  const button = rootElement.querySelector<HTMLButtonElement>(".cv-image-placeholder__load");
  expect(button).not.toBeNull();
  await act(async () => button!.click());
  await flush();
  expect(rootElement.querySelectorAll("img.cv-img").length).toBe(1);

  seedLinkStore({ policy: { remoteImages: "always" } });
  await images(autos);
  await flush();
  expect(rootElement.querySelectorAll("img.cv-img").length).toBe(autos.length);
  await act(async () => root.render(null));

  // Back under "click": the clicked image draws at once, without a load or a placeholder.
  seedLinkStore({ policy: { remoteImages: "click" } });
  const before = loads.length;
  await images([clicked]);
  expect(rootElement.querySelectorAll("img.cv-img").length).toBe(1);
  expect(rootElement.querySelector(".cv-image-placeholder")).toBeNull();
  expect(loads.length).toBe(before);
  await act(async () => root.render(null));

  // The oldest automatic image was forgotten and loads again; the newest is still cached.
  seedLinkStore({ policy: { remoteImages: "always" } });
  await images([autos[0]!, autos.at(-1)!]);
  await flush();
  expect(loads.slice(before)).toEqual([autos[0]!]);
  expect(rootElement.querySelectorAll("img.cv-img").length).toBe(2);

  await act(async () => root.unmount());
  setChipHost(undefined);
  resetLinkStore();
});
