// A video attached to a Home message pops out into the lightbox like an image (Leo 2026-11-04: "i
// can neither preview a vid in place nor have it pop up anymore :("; 2026-10-25: "also why dont we
// have previews of videos we should"). Its Expand opens it large, paused until Play, as the agent
// chat's VideoViewer does; the arrow keys move among the message's images and videos; Escape closes;
// it still plays in place.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AttachmentService } from "../src/pages/home-channels/attachmentService";
import type { HomeAttachment } from "../src/pages/home-channels/types";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

const DIALOG_GLOBALS = [
  "Node",
  "Element",
  "SVGElement",
  "HTMLIFrameElement",
  "DocumentFragment",
  "ShadowRoot",
  "Event",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "MutationObserver",
  "getComputedStyle",
];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    pretendToBeVisual: true,
    url: "http://localhost/",
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "IS_REACT_ACT_ENVIRONMENT",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    ...DIALOG_GLOBALS,
  ])
    saved.set(key, scope[key]);
  for (const key of DIALOG_GLOBALS) scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const frame = (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number;
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: frame,
    cancelAnimationFrame: (id: number) => clearTimeout(id),
  });
  Object.assign(dom.window, { requestAnimationFrame: frame, cancelAnimationFrame: (id: number) => clearTimeout(id) });
  const media = dom.window.HTMLMediaElement.prototype as unknown as Record<string, unknown>;
  media.play = function play(this: HTMLMediaElement) {
    this.dataset.played = this.muted ? "muted" : "sound";
    return Promise.resolve();
  };
  media.pause = function pause(this: HTMLMediaElement) {
    this.dataset.paused = "yes";
  };
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const VIDEO_URL = "http://localhost/attachments/run.mp4";

const image: HomeAttachment = {
  type: "attachment",
  hash: "a".repeat(64),
  name: "before.png",
  mimeType: "image/png",
  byteCount: 2048,
  width: 1600,
  height: 1000,
};
const video: HomeAttachment = {
  type: "attachment",
  hash: "f".repeat(64),
  name: "run.mp4",
  mimeType: "video/mp4",
  byteCount: 2_300_000,
  width: 1280,
  height: 720,
  durationMs: 6_000,
};

async function mount({ videoFails = false } = {}) {
  const container = installDom();
  const { AttachmentContext, MessageAttachments } = await import("../src/pages/home-channels/AttachmentViews");
  const { createStrings } = await import("../src/pages/shared/i18n");
  const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
  const strings = createStrings(table, ["en"]);
  const service = {
    image: async () => PNG,
    url: async (_conversation: string, hash: string) => {
      if (hash === video.hash && videoFails) throw new Error("the daemon does not answer");
      return hash === video.hash ? VIDEO_URL : PNG;
    },
  } as unknown as AttachmentService;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <AttachmentContext.Provider value={service}>
        <MessageAttachments conversation="c" parts={[image, video]} strings={strings} />
      </AttachmentContext.Provider>,
    );
  });
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const document = dom!.window.document;
  const lightbox = () => document.querySelector<HTMLElement>(".hc-lightbox");
  const title = () => lightbox()?.querySelector(".hc-lightbox-bar .hc-att-name")?.textContent;
  // Lets React and the attachment service settle until `reached` holds: a poll of the real state, bounded by a
  // deadline, not one fixed tick that hopes the lightbox has rendered. It always lets one tick run, as the
  // lightbox moves focus to itself after it renders.
  const until = async (reached: () => boolean) => {
    const deadline = Date.now() + 5_000;
    do {
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    } while (!reached() && Date.now() < deadline);
  };
  const press = async (key: string) => {
    const target = document.activeElement ?? document.body;
    await act(async () => {
      target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  };
  const expand = async () => {
    const button = container.querySelector<HTMLButtonElement>(".hc-att-video button.hc-att-expand");
    expect(button).not.toBeNull();
    expect(button!.getAttribute("aria-label")).toBe(strings.format("attachment.expand", video.name));
    await act(async () => button!.click());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  };
  return { container, document, strings, lightbox, title, press, expand, until };
}

test("a video's Expand opens it in the lightbox, paused, and Escape closes it", async () => {
  const { container, lightbox, title, press, expand } = await mount();
  const inline = container.querySelector<HTMLVideoElement>(".hc-att-video video")!;
  expect(inline.getAttribute("src")).toBe(VIDEO_URL);
  await expand();
  expect(title()).toBe("run.mp4");
  expect(lightbox()!.querySelector(".hc-lightbox-bar .hc-att-meta")?.textContent).toContain("2 / 2");
  const large = lightbox()!.querySelector<HTMLVideoElement>(".hc-lightbox-stage video")!;
  expect(large).not.toBeNull();
  expect(large.getAttribute("src")).toBe(VIDEO_URL);
  // Opens paused, like the agent chat's large player: nothing plays until Play.
  expect(large.hasAttribute("autoplay")).toBe(false);
  expect(large.dataset.played).toBeUndefined();
  expect(lightbox()!.querySelector("button.cv-media__poster")).not.toBeNull();
  await press("Escape");
  expect(lightbox()).toBeNull();
  // It still plays in place.
  expect(container.querySelector<HTMLVideoElement>(".hc-att-video video")?.controls).toBe(true);
});

test("the arrow keys move from an image to the video and back", async () => {
  const { container, lightbox, title, press, until } = await mount();
  await act(async () => container.querySelector<HTMLButtonElement>(".hc-att-image")!.click());
  await until(() => title() === "before.png");
  expect(title()).toBe("before.png");
  expect(lightbox()!.querySelector(".hc-lightbox-stage img")).not.toBeNull();
  await press("ArrowRight");
  expect(title()).toBe("run.mp4");
  expect(lightbox()!.querySelector(".hc-lightbox-stage video")?.getAttribute("src")).toBe(VIDEO_URL);
  expect(lightbox()!.querySelector(".hc-lightbox-stage img")).toBeNull();
  await press("ArrowLeft");
  expect(title()).toBe("before.png");
  await press("ArrowLeft");
  expect(title()).toBe("run.mp4");
});

test("Play in the lightbox takes over the inline player's position; closing hands it back", async () => {
  const { container, lightbox, expand } = await mount();
  const inline = container.querySelector<HTMLVideoElement>(".hc-att-video video")!;
  inline.currentTime = 12;
  await expand();
  const large = lightbox()!.querySelector<HTMLVideoElement>(".hc-lightbox-stage video")!;
  await act(async () => lightbox()!.querySelector<HTMLButtonElement>("button.cv-media__poster")!.click());
  expect(inline.dataset.paused).toBe("yes");
  expect(large.currentTime).toBe(12);
  expect(large.dataset.played).toBe("sound");
  expect(large.controls).toBe(true);
  large.currentTime = 30;
  await act(async () => lightbox()!.querySelector<HTMLButtonElement>(".hc-lightbox-bar button")!.click());
  expect(lightbox()).toBeNull();
  expect(inline.currentTime).toBe(30);
});

test("a video whose link cannot be had says so in the lightbox", async () => {
  const { strings, lightbox, title, expand } = await mount({ videoFails: true });
  await expand();
  expect(title()).toBe("run.mp4");
  expect(lightbox()!.querySelector(".hc-lightbox-stage video")).toBeNull();
  expect(lightbox()!.querySelector(".hc-lightbox-unread")?.textContent).toContain(
    strings.t("lightbox.videoUnavailable"),
  );
});
