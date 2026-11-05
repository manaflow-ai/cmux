// A queued prompt's card stays one compact line of attachments. Leo, 2026-11-05, after a message
// with three screen recordings queued behind a busy turn and its card drew every frame of each
// video (23 thumbnails over three rows): "uh this was a weird preview idk i guess i accidentally
// queued?".
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComposerQueue } from "./ComposerQueue";
import { queuedTiles } from "./QueuedImages";
import type { QueuedPromptImage } from "./model";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of KEYS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const t = (key: string, values?: Record<string, unknown>) =>
  values ? `${key}(${Object.values(values).join(",")})` : key;
const image = (id: string, name: string): QueuedPromptImage => ({
  id,
  mimeType: "image/jpeg",
  name,
  src: `data:image/jpeg;base64,${id}`,
});
/// A video's frames as acpmux lists them: one image each, named `<video> frame at <time>`.
const frames = (video: string, count: number) =>
  Array.from({ length: count }, (_, at) => image(`${video}-${at}`, `${video} frame at 0:0${at}.0`));
// Leo's message: three screen recordings and two screenshots.
const LEOS = [
  image("shot-1", "Screenshot 1.png"),
  ...frames("Screen Recording 1.mov", 7),
  ...frames("Screen Recording 2.mov", 7),
  ...frames("Screen Recording 3.mov", 7),
  image("shot-2", "Screenshot 2.png"),
];

async function render(queue: Parameters<typeof ComposerQueue>[0]["queue"]) {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<ComposerQueue queue={queue} chat="c" t={t as never} onChange={async () => true} />);
  });
  return container;
}

test("a video's frames are one tile, with its first frame and its length", () => {
  expect(LEOS.length).toBe(23);
  const tiles = queuedTiles(LEOS, [{ name: "Screen Recording 2.mov", durationMs: 16_000, frames: 7 }]);
  expect(tiles.map((tile) => (tile.kind === "video" ? `video:${tile.name}` : `image:${tile.image.name}`))).toEqual([
    "image:Screenshot 1.png",
    "video:Screen Recording 1.mov",
    "video:Screen Recording 2.mov",
    "video:Screen Recording 3.mov",
    "image:Screenshot 2.png",
  ]);
  const second = tiles[2]!;
  expect(second.kind === "video" && second.poster.id).toBe("Screen Recording 2.mov-0");
  expect(second.kind === "video" && second.durationMs).toBe(16_000);
  expect(second.kind === "video" && second.ids.length).toBe(7);
});

test("two videos of one name stay two tiles", () => {
  const tiles = queuedTiles([...frames("clip.mov", 3), ...frames("clip.mov", 2)]);
  expect(tiles.map((tile) => (tile.kind === "video" ? tile.ids.length : 0))).toEqual([3, 2]);
});

test("two videos of one name stay two tiles, each with its own frames and length", () => {
  // A 1-second clip.mov sampled at 0.2, 0.5 and 0.8 s, then a 16-second clip.mov whose frames start
  // at 1 s: the times go on across the two, so only the prompt's own videos tell them apart.
  const at = (id: string, time: string) => image(id, `clip.mov frame at ${time}`);
  const images = [at("a0", "0:00.2"), at("a1", "0:00.5"), at("a2", "0:00.8"), at("b0", "0:01.0"), at("b1", "0:08.0")];
  const video = (durationMs: number, times: number[]) => ({ name: "clip.mov", durationMs, frames: times.length });
  const tiles = queuedTiles(images, [video(1_000, [200, 500, 800]), video(16_000, [1_000, 8_000])]);
  expect(tiles.map((tile) => (tile.kind === "video" ? [tile.ids, tile.durationMs] : []))).toEqual([
    [["a0", "a1", "a2"], 1_000],
    [["b0", "b1"], 16_000],
  ]);
});

test("Leo's queued message draws five tiles in one row, never its 23 frames", async () => {
  const container = await render([{ id: "p-1", prompt: "look at these", images: LEOS }]);
  const row = container.querySelector('[data-prompt-id="p-1"]')!;
  expect(row.querySelectorAll(".acpmux-queued-image-slot").length).toBe(5);
  expect(row.querySelectorAll(".acpmux-queued-image-slot[data-video]").length).toBe(3);
  expect(row.querySelector(".acpmux-queued-images-more")).toBeNull();
});

test("past one row's tiles, the rest is one +N", async () => {
  const many = Array.from({ length: 10 }, (_, at) => image(`img-${at}`, `Shot ${at}.png`));
  const container = await render([{ id: "p-1", prompt: "many", images: many }]);
  const row = container.querySelector('[data-prompt-id="p-1"]')!;
  expect(row.querySelectorAll(".acpmux-queued-image-slot").length).toBe(5);
  expect(row.querySelector(".acpmux-queued-images-more")?.textContent).toBe("multiplayer.more(5)");
});
