// l10n-allow-file: test fixtures.
// A file chip in the transcript (Leo, 2026-10-31: "THE OPEN BUTTON DOESN'T WORK", "I SHOULDN'T EVEN
// HAVE TO CLICK THE OPEN BUTTON IT SHOULD JUST PREVIEW"): a template path is plain text, an image
// that exists previews with no click (outside the chat's folders too, under `outsideRoots: open`),
// a file that is not there has no Open, and Open asks the host to open the path it names.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { isImagePath, isTemplatePath, linkPath } from "../src/agent-session/acpmux/chips/paths";
import { bareImageSource } from "../src/agent-session/acpmux/conversation/inlineMedia";
import { toolImages } from "../src/agent-session/acpmux/toolImages";

const TEMPLATE = "/Users/me/site/public/${variant}-320.png";
const OUTSIDE = "/Volumes/Shots/sidebar-320.png";
const GONE = "/Volumes/Shots/gone-320.png";
// Its own path: an image that loaded once stays cached for the page's life (ReplyImage `loaded`).
const GATED = "/Volumes/Shots/gated-320.png";
const IMAGE = "data:image/png;base64,iVBORw0KGgo=";

describe("template paths", () => {
  test.each([TEMPLATE, "/a/{{name}}.png", "/a/<file>.png", "/a/out/*.png"])("%s is a template", (path) => {
    expect(isTemplatePath(path)).toBe(true);
    expect(isImagePath(path)).toBe(false);
    expect(bareImageSource(path)).toBeUndefined();
    expect(linkPath(path)).toBeUndefined();
  });

  test("a real path is not a template", () => {
    expect(isTemplatePath(OUTSIDE)).toBe(false);
    expect(isImagePath(OUTSIDE)).toBe(true);
  });

  test("a tool's output names no template image", () => {
    const tool = {
      id: "t",
      title: "Read",
      kind: "read" as const,
      status: "completed" as const,
      output: `const src = \`${TEMPLATE}\`;\nwrote ${OUTSIDE}\n`,
    };
    expect(toolImages(tool)).toEqual([OUTSIDE]);
  });
});

describe("rendered", () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "IS_REACT_ACT_ENVIRONMENT",
  ] as const;
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

  const calls: Array<[string, Record<string, unknown>]> = [];
  async function render(
    element: (h: typeof import("react").createElement) => import("react").ReactElement,
    outsideRoots: "open" | "confirm" | "text",
    answer: "image" | "none" = "image",
  ) {
    const { act, createElement } = await import("react");
    const { createRoot } = await import("react-dom/client");
    const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    resetLinkStore();
    seedLinkStore({
      paths: {
        [OUTSIDE]: { place: "outside", folder: false },
        [GATED]: { place: "outside", folder: false },
        [GONE]: { place: "missing", folder: false },
      },
      policy: { outsideRoots, remoteImages: "click", clickFreeImageHosts: [] },
    });
    calls.length = 0;
    setChipHost(async (method, params) => {
      calls.push([method, params]);
      if (method === "image.load") return answer === "image" ? { src: IMAGE } : undefined;
      return {};
    });
    const container = dom.window.document.createElement("div");
    dom.window.document.body.append(container);
    const root = createRoot(container);
    await act(async () => root.render(element(createElement)));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    return { container, act, unmount: () => act(async () => root.unmount()) };
  }

  test("a template path renders no chip, only its text", async () => {
    const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
    const { container, unmount } = await render(
      (h) => h(ReplyImage, { src: TEMPLATE, alt: "", fallback: "fallback", thumb: true }),
      "open",
    );
    expect(container.querySelector(".cv-image-file")).toBeNull();
    expect(container.querySelector("button")).toBeNull();
    expect(container.querySelector(".cv-chip-plain")?.textContent).toBe("${variant}-320.png");
    expect(calls).toEqual([]);
    await unmount();
  });

  test("an existing image outside the folders draws its thumbnail with no click under open", async () => {
    const { ToolImages } = await import("../src/agent-session/acpmux/conversation/ToolRow");
    const { container, unmount } = await render((h) => h(ToolImages, { sources: [OUTSIDE] }), "open");
    expect(container.querySelector(".cv-tool-images .cv-thumb img.cv-thumb__img")).not.toBeNull();
    expect(container.querySelector(".cv-image-file")).toBeNull();
    expect(calls.filter(([method]) => method === "image.load").map(([, params]) => params.src)).toEqual([OUTSIDE]);
    await unmount();
  });

  test("a file that is not there has no Open, and a tool's strip draws nothing for it", async () => {
    const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
    const { ToolImages } = await import("../src/agent-session/acpmux/conversation/ToolRow");
    const reply = await render((h) => h(ReplyImage, { src: GONE, alt: "", fallback: "fallback", thumb: true }), "open");
    expect(reply.container.querySelector(".cv-image-file__open")).toBeNull();
    await reply.unmount();
    const strip = await render((h) => h(ToolImages, { sources: [GONE] }), "open");
    expect(strip.container.querySelector(".cv-tool-images")?.children.length).toBe(0);
    await strip.unmount();
  });

  test("Open asks the host to open the path the chip names", async () => {
    const { ReplyImage } = await import("../src/agent-session/acpmux/chips/ReplyImage");
    const { container, act, unmount } = await render(
      (h) => h(ReplyImage, { src: GATED, alt: "", fallback: "fallback" }),
      "confirm",
    );
    const open = container.querySelector<HTMLButtonElement>(".cv-image-file__open");
    expect(open).not.toBeNull();
    await act(async () => open!.click());
    expect(calls).toContainEqual(["link.openPath", { path: GATED }]);
    expect(calls.some(([method]) => method === "image.load")).toBe(false);
    await unmount();
  });
});
