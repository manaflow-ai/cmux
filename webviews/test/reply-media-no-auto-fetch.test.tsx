// l10n-allow-file: test fixture replies, not shipped UI.
// No automatic fetch and no automatic open from an agent's media (media-safety plan R5 and R7,
// leo-workspace#874). Leo 2026-10-21: "we want to make it prompt injection safe as well since
// images to remote is maybe dangerous to remote". With the default `agentPane.images.remote`
// (`click`), a reply's web image or video asks the host for nothing until the reader clicks Load,
// the page itself names no web, app or file URL in any element that loads or navigates, and
// rendering, hovering or playing media never asks the host to open anything. The page's shipped
// CSPs give it no network of its own.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";

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
  // JSDOM has no media playback; hovering a video calls play().
  dom.window.HTMLMediaElement.prototype.play = () => Promise.resolve();
  dom.window.HTMLMediaElement.prototype.pause = () => {};
});
afterAll(async () => {
  // fixed-wait: teardown only; React's scheduled work runs before its window closes
  await new Promise((resolve) => setTimeout(resolve, 20));
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const PNG = "data:image/png;base64,iVBORw0KGgo=";
const MEDIA = "cmux-agent://pane/__media/0123456789abcdef.mp4";
const WEB_IMAGE = "https://images.example.com/tracker.png";
const WEB_VIDEO = "https://media.example.com/clip.mp4";
const HOSTILE_SVG =
  "data:image/svg+xml;base64," +
  btoa(
    `<svg xmlns="http://www.w3.org/2000/svg" onload="location='cmux://workspace/ws_x'">` +
      `<a href="cmux://workspace/ws_0123456789abcdef0123456789abcdef"><rect width="9" height="9"/></a></svg>`,
  );
/** A reply holding every kind of agent media the pane draws, plus app, script and file links as images. */
const REPLY = [
  `![shot](/tmp/project/shot.png)`,
  "",
  `![clip](/tmp/project/clip.mp4)`,
  "",
  `![tracker](${WEB_IMAGE})`,
  "",
  WEB_VIDEO,
  "",
  `![svg](${HOSTILE_SVG})`,
  "",
  `![app](cmux://workspace/ws_0123456789abcdef0123456789abcdef)`,
  "",
  `![script](javascript:alert(1))`,
  "",
  `![file](file:///etc/passwd.png)`,
].join("\n");

/** The host calls that read only; anything else the page asks for (an open, a reveal, a browser) is an effect. */
const PASSIVE = new Set(["link.inspect", "image.load", "media.load"]);

type Call = { method: string; params: Record<string, unknown> };

async function render(markdown: string, remoteImages: "click" | "never" = "click") {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { ImageViewerContext } = await import("../src/agent-session/acpmux/conversation/imageViewerContext");
  const { resetLinkStore, seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  resetLinkStore();
  seedLinkStore({
    paths: {
      "/tmp/project/shot.png": { place: "root", folder: false },
      "/tmp/project/clip.mp4": { place: "root", folder: false },
    },
    policy: { remoteImages, outsideRoots: "confirm" },
  });
  const calls: Call[] = [];
  const viewed: string[] = [];
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    if (method === "image.load") return { src: PNG };
    if (method === "media.load") return { src: MEDIA };
    return {};
  });
  const container = dom.window.document.createElement("div");
  dom.window.document.body.append(container);
  const root = createRoot(container);
  const openImage = (src: string) => void viewed.push(src);
  await act(async () =>
    root.render(
      <ImageViewerContext.Provider value={openImage}>
        <Markdown>{markdown}</Markdown>
      </ImageViewerContext.Provider>,
    ),
  );
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return {
    container,
    calls,
    viewed,
    act,
    settle,
    unmount: async () => {
      await act(async () => root.unmount());
      container.remove();
      setChipHost(undefined);
      resetLinkStore();
    },
  };
}

/** Every URL an element of `container` would load or navigate to by itself. */
function loadingURLs(container: Element): string[] {
  const out: string[] = [];
  for (const element of container.querySelectorAll("*")) {
    for (const name of ["src", "srcset", "poster", "data", "background", "action", "formaction"]) {
      const value = element.getAttribute(name);
      if (value) out.push(value);
    }
    if (element.localName === "a" || element.localName === "area" || element.localName === "link") {
      const href = element.getAttribute("href");
      if (href) out.push(href);
    }
  }
  return out;
}

const srcs = (calls: Call[], method: string) =>
  calls.filter((call) => call.method === method).map((call) => String(call.params.src));

describe("R5: no automatic fetch", () => {
  test("a web image and a web video ask the host for nothing until Load is clicked", async () => {
    const page = await render(REPLY);
    expect(srcs(page.calls, "image.load")).not.toContain(WEB_IMAGE);
    expect(srcs(page.calls, "media.load")).not.toContain(WEB_VIDEO);
    // The page itself names no web address in anything that loads: the host fetches, or nothing does.
    const loads = loadingURLs(page.container).filter((url) => !url.startsWith("data:image/") && url !== MEDIA);
    expect(loads.filter((url) => /^(https?|cmux[\w-]*|javascript|file):/i.test(url))).toEqual([]);

    const imageLoad = page.container.querySelector<HTMLButtonElement>(
      ".cv-image-placeholder .cv-image-placeholder__load",
    );
    expect(imageLoad).not.toBeNull();
    await page.act(async () => imageLoad!.click());
    await page.settle();
    expect(srcs(page.calls, "image.load").filter((src) => src === WEB_IMAGE)).toEqual([WEB_IMAGE]);

    const videoLoad = page.container.querySelector<HTMLButtonElement>(
      ".cv-media.is-remote .cv-image-placeholder__load",
    );
    expect(videoLoad).not.toBeNull();
    await page.act(async () => videoLoad!.click());
    await page.settle();
    expect(srcs(page.calls, "media.load").filter((src) => src === WEB_VIDEO)).toEqual([WEB_VIDEO]);
    await page.unmount();
  });

  test("under never, a web image and video offer no Load and ask for nothing", async () => {
    const page = await render(REPLY, "never");
    expect(page.container.querySelector(".cv-image-placeholder__load")).toBeNull();
    expect(srcs(page.calls, "image.load")).not.toContain(WEB_IMAGE);
    expect(srcs(page.calls, "media.load")).not.toContain(WEB_VIDEO);
    await page.unmount();
  });

  test("an app or script URL written as an image is never asked for; nothing links an app, script or file URL", async () => {
    const page = await render(REPLY);
    // (A file URL is a local path: the host checks it against the session's folders, R1.)
    const asked = [...srcs(page.calls, "image.load"), ...srcs(page.calls, "media.load")];
    expect(asked.filter((src) => /^(cmux[\w-]*|javascript):/i.test(src))).toEqual([]);
    // The pane's own media URL (`cmux-agent://pane/__media/`) is the one app URL an element may name.
    const named = loadingURLs(page.container).filter((url) => url !== MEDIA);
    expect(named.filter((url) => /^(cmux[\w-]*|javascript|file):/i.test(url))).toEqual([]);
    await page.unmount();
  });

  test("the shipped page CSPs give the page no network: images are data:, media is the pane's own", () => {
    const script = fs.readFileSync(
      path.join(import.meta.dir, "../../scripts/cmux-next/build-agent-pane-web.sh"),
      "utf8",
    );
    const bundled = script.match(/^CSP="([^"]+)"/m)?.[1];
    const hosted = fs.readFileSync(path.join(import.meta.dir, "fixtures/agent-page-csp.txt"), "utf8").trim();
    for (const csp of [bundled, hosted]) {
      expect(csp).toBeDefined();
      const directives = new Map(
        csp!
          .split(";")
          .map((part) => part.trim().split(/\s+/))
          .filter((parts) => parts[0])
          .map((parts) => [parts[0]!, parts.slice(1)] as const),
      );
      expect(directives.get("default-src")).toEqual(["'none'"]);
      expect(directives.get("connect-src")).toEqual(["'none'"]);
      for (const name of ["img-src", "media-src"]) {
        const sources = directives.get(name) ?? directives.get("default-src")!;
        expect(sources.every((source) => ["'self'", "data:", "'none'"].includes(source))).toBe(true);
      }
    }
  });
});

describe("R7: no action from media", () => {
  test("rendering, hovering, playing and clicking agent media asks the host to open nothing", async () => {
    const page = await render(REPLY);
    const video = page.container.querySelector("video");
    expect(video?.getAttribute("src")).toBe(MEDIA);
    await page.act(async () => {
      video!.dispatchEvent(new dom.window.MouseEvent("mouseenter", { bubbles: true }));
      video!.dispatchEvent(new dom.window.Event("play"));
      video!.dispatchEvent(new dom.window.MouseEvent("mouseleave", { bubbles: true }));
    });
    // A click on a shown image opens cmux's own image viewer, never the host.
    const images = [...page.container.querySelectorAll<HTMLButtonElement>("button[data-open-image]")];
    expect(images.length).toBeGreaterThan(0);
    for (const image of images) await page.act(async () => image.click());
    await page.settle();
    expect(page.viewed.length).toBe(images.length);
    expect(page.calls.filter((call) => !PASSIVE.has(call.method))).toEqual([]);
    // The hostile SVG draws only as an image (WebKit runs no script and follows no link in one).
    const svg = [...page.container.querySelectorAll("img")].filter((img) =>
      img.getAttribute("src")?.startsWith("data:image/svg+xml"),
    );
    expect(svg.length).toBe(1);
    expect(page.container.querySelector("svg a, object, embed, iframe")).toBeNull();
    await page.unmount();
  });
});
