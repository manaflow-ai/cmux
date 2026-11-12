// Leo, 2026-11-12: "The video playing thing, I need to be able to, like, click outside of the video
// and have that exit as well, but right now it's not doing that. It works for attachments like
// pictures though." Every media viewer closes the same way (ui/scrimClose.ts): a click beside the
// media closes it, a click on the media or its controls does not, and Escape closes it.
import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { VideoViewer } from "../chips/ReplyMedia";
import { ImageViewer } from "./ImageViewer";

// Base UI's focus code schedules frames that may run after a test: the frame functions stay installed
// for the whole file, and go when it ends (the frames still pending then are cleared with them).
const frames = {
  requestAnimationFrame: globalThis.requestAnimationFrame,
  cancelAnimationFrame: globalThis.cancelAnimationFrame,
};
installFrames();
afterAll(() => {
  const globals = globalThis as Record<string, unknown>;
  for (const [key, value] of Object.entries(frames)) {
    if (value === undefined) delete globals[key];
    else globals[key] = value;
  }
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "KeyboardEvent",
  "MouseEvent",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

function installFrames() {
  const globals = globalThis as Record<string, unknown>;
  globals.requestAnimationFrame ??= (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0);
  globals.cancelAnimationFrame ??= (id: number) => clearTimeout(id);
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) if (!saved.has(key)) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    MouseEvent: dom.window.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
  act(() => root!.render(node));
  return dom.window.document;
}

/// A press and its click on `element` itself, as a pointer would: mousedown, mouseup, click.
function click(element: Element) {
  const view = element.ownerDocument.defaultView!;
  act(() => {
    for (const type of ["mousedown", "mouseup", "click"])
      element.dispatchEvent(new view.MouseEvent(type, { bubbles: true, cancelable: true, detail: 1, button: 0 }));
  });
}

function escape(document: Document) {
  const target = document.activeElement ?? document.body;
  act(() => {
    target.dispatchEvent(
      new document.defaultView!.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );
  });
}

function video(document: Document): HTMLVideoElement {
  const found = document.querySelector<HTMLVideoElement>(".acpmux-image-viewer video");
  if (!found) throw new Error("the video viewer has no video");
  return found;
}

function videoStage(document: Document): HTMLElement {
  const found = document.querySelector<HTMLElement>(".acpmux-image-viewer .cv-media-stage");
  if (!found) throw new Error("the video viewer has no stage");
  return found;
}

test("a click beside the video closes the video viewer", () => {
  let closed = 0;
  const document = render(<VideoViewer src="clip.mp4" name="clip.mp4" onError={() => {}} onClose={() => closed++} />);
  click(videoStage(document));
  expect(closed).toBe(1);
});

test("a click on a playing video or its frame does not close the video viewer", () => {
  let closed = 0;
  const document = render(
    <VideoViewer src="clip.mp4" name="clip.mp4" autoPlay onError={() => {}} onClose={() => closed++} />,
  );
  click(video(document));
  click(document.querySelector(".acpmux-image-viewer .cv-media__frame")!);
  expect(closed).toBe(0);
});

test("a click on the paused video's play button does not close the video viewer", () => {
  let closed = 0;
  const document = render(<VideoViewer src="clip.mp4" name="clip.mp4" onError={() => {}} onClose={() => closed++} />);
  const play = document.querySelector(".acpmux-image-viewer .cv-media__poster");
  if (!play) throw new Error("the paused video viewer has no play button");
  click(play);
  expect(closed).toBe(0);
});

test("a scrub that starts on the video and ends beside it does not close the video viewer", () => {
  let closed = 0;
  const document = render(
    <VideoViewer src="clip.mp4" name="clip.mp4" autoPlay onError={() => {}} onClose={() => closed++} />,
  );
  const view = document.defaultView!;
  act(() => {
    video(document).dispatchEvent(new view.MouseEvent("mousedown", { bubbles: true, detail: 1, button: 0 }));
    videoStage(document).dispatchEvent(new view.MouseEvent("mouseup", { bubbles: true, detail: 1, button: 0 }));
    videoStage(document).dispatchEvent(new view.MouseEvent("click", { bubbles: true, detail: 1, button: 0 }));
  });
  expect(closed).toBe(0);
});

test("a pan that starts on the image and ends beside it does not close the image viewer", () => {
  let closed = 0;
  const document = render(
    <ImageViewer images={[{ src: "a.png", alt: "A" }]} index={0} onIndex={() => {}} onClose={() => closed++} />,
  );
  const view = document.defaultView!;
  const stage = document.querySelector(".acpmux-image-viewer-stage")!;
  act(() => {
    document
      .querySelector(".acpmux-image-viewer-image")!
      .dispatchEvent(new view.MouseEvent("mousedown", { bubbles: true, detail: 1, button: 0 }));
    stage.dispatchEvent(new view.MouseEvent("click", { bubbles: true, detail: 1, button: 0 }));
  });
  expect(closed).toBe(0);
});

test("Escape closes the video viewer", () => {
  let closed = 0;
  const document = render(<VideoViewer src="clip.mp4" name="clip.mp4" onError={() => {}} onClose={() => closed++} />);
  escape(document);
  expect(closed).toBe(1);
});

test("the second click of the double click that opened the video viewer does not close it", () => {
  let closed = 0;
  const document = render(<VideoViewer src="clip.mp4" name="clip.mp4" onError={() => {}} onClose={() => closed++} />);
  const stage = videoStage(document);
  const view = document.defaultView!;
  act(() => {
    stage.dispatchEvent(new view.MouseEvent("mousedown", { bubbles: true, detail: 2, button: 0 }));
    stage.dispatchEvent(new view.MouseEvent("click", { bubbles: true, detail: 2, button: 0 }));
  });
  expect(closed).toBe(0);
});

test("the image viewer keeps closing on a click beside the image, not on the image, and on Escape", () => {
  let closed = 0;
  const images = [{ src: "a.png", alt: "A" }];
  const document = render(<ImageViewer images={images} index={0} onIndex={() => {}} onClose={() => closed++} />);
  click(document.querySelector(".acpmux-image-viewer-image")!);
  expect(closed).toBe(0);
  click(document.querySelector(".acpmux-image-viewer-stage")!);
  expect(closed).toBe(1);
  escape(document);
  expect(closed).toBe(2);
});
