// An attached video loads in one look (Leo, 2026-11-08: "it is bad that there are 2+ loading states
// it goes from themed opaque (which is frequently ugly) into unthemed then to loaded"): from the
// first frame its chip shows to its poster, the tile wears the loading glass (pasteLoadingLook.ts),
// never the neutral square (`-unread`) that only a video the host could not read keeps.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ComposerAttachment } from "../attachments";
import { settleReact } from "../../../../test/support/domTeardown";
import { setChipHost } from "../chips/host";
import { useVideoInfo } from "./videoAttachments";
import { VideoAttachmentTile } from "./VideoAttachmentTile";

const POSTER = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQ==";
const INFO = { durationMs: 42_000, width: 1920, height: 1080, poster: POSTER, frames: [] };

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  setChipHost(undefined);
});

type Pending = { src: string; answer(value: unknown): void; refuse(): void };

/// Mounts a composer strip of video chips against a host whose `video.info` answers only when the
/// test says so; every other video read is refused. Answers the strip's container, a way to attach
/// a video, the reads asked so far, and each commit's tile classes, by chip id.
async function mount() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    if (!saved.has(key)) saved.set(key, scope[key]);
  const asked: Pending[] = [];
  setChipHost((method, params) =>
    method === "video.info"
      ? new Promise((resolve, reject) => {
          asked.push({ src: String(params.src), answer: resolve, refuse: () => reject(new Error("refused")) });
        })
      : Promise.reject(new Error("refused")),
  );
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  /// Every committed look of each tile, read in a layout effect (before paint).
  const looks = new Map<string, string[]>();
  let add: (chip: ComposerAttachment) => void = () => {};
  function Strip() {
    const [chips, setChips] = useState<ComposerAttachment[]>([]);
    add = (chip) => setChips((current) => [...current, chip]);
    useVideoInfo(chips, setChips, true);
    return (
      <>
        {chips.map((chip) => (
          <VideoAttachmentTile
            key={chip.id}
            id={chip.id}
            name={chip.name}
            video={chip.video}
            shape={16 / 9}
            remove={null}
            onPlay={() => {}}
          />
        ))}
      </>
    );
  }
  const container = dom.window.document.getElementById("root")!;
  const record = () => {
    for (const tile of container.querySelectorAll<HTMLElement>(".acpmux-attachment-video")) {
      const id = tile.dataset.testId ?? tile.title;
      looks.set(id, [...(looks.get(id) ?? []), look(tile)]);
    }
  };
  const observer = new dom.window.MutationObserver(record);
  observer.observe(container, { subtree: true, childList: true, attributes: true });
  await act(async () => {
    root = createRoot(container);
    root.render(<Strip />);
  });
  const attach = async (name: string) => {
    await act(async () =>
      add({ id: name, kind: "link", name, path: `/Users/dev/Desktop/${name}` } as ComposerAttachment),
    );
    record();
  };
  return { container, attach, asked, looks };
}

/// A tile's look: loading (the glass), its poster, or the neutral square.
function look(tile: HTMLElement): string {
  if (tile.querySelector("img")) return tile.classList.contains("acpmux-paste-loading") ? "poster+loading" : "poster";
  if (tile.classList.contains("acpmux-attachment-video-unread"))
    return tile.classList.contains("acpmux-paste-loading") ? "square+loading" : "square";
  return tile.classList.contains("acpmux-paste-loading") ? "loading" : "bare";
}

const flush = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const distinct = (seen: string[] | undefined) => (seen ?? []).filter((value, index, all) => all[index - 1] !== value);

test("two videos attached one after the other each load in one look, then show their posters", async () => {
  const { container, attach, asked, looks } = await mount();
  await attach("first.mov");
  await attach("second.mov");
  // Both are asked at once, and both wear the loading glass, from their first frame on.
  expect(asked.map((read) => read.src)).toEqual(["/Users/dev/Desktop/first.mov", "/Users/dev/Desktop/second.mov"]);
  const tiles = [...container.querySelectorAll<HTMLElement>(".acpmux-attachment-video")];
  expect(tiles.map(look)).toEqual(["loading", "loading"]);
  expect(tiles.every((tile) => tile.getAttribute("aria-busy") === "true")).toBe(true);
  // The second answers first; then the first.
  asked[1]!.answer(INFO);
  await flush();
  expect([...container.querySelectorAll<HTMLElement>(".acpmux-attachment-video")].map(look)).toEqual([
    "loading",
    "poster",
  ]);
  asked[0]!.answer(INFO);
  await flush();
  expect([...container.querySelectorAll<HTMLElement>(".acpmux-attachment-video")].map(look)).toEqual([
    "poster",
    "poster",
  ]);
  // Every look each tile ever committed: loading, then its poster, nothing between.
  expect(distinct(looks.get("first.mov"))).toEqual(["loading", "poster"]);
  expect(distinct(looks.get("second.mov"))).toEqual(["loading", "poster"]);
});

test("a video the host could not read goes from loading to its square, once", async () => {
  const { container, attach, asked, looks } = await mount();
  await attach("broken.mov");
  expect(look(container.querySelector<HTMLElement>(".acpmux-attachment-video")!)).toBe("loading");
  asked[0]!.refuse();
  await flush();
  const tile = container.querySelector<HTMLElement>(".acpmux-attachment-video")!;
  expect(look(tile)).toBe("square");
  expect(tile.hasAttribute("aria-busy")).toBe(false);
  expect(distinct(looks.get("broken.mov"))).toEqual(["loading", "square"]);
});

test("a tile with no read (a chat on another machine, a gallery tile) is its square", async () => {
  const { container } = await mount();
  await act(async () =>
    root!.render(<VideoAttachmentTile name="remote.mov" video={undefined} shape={1} remove={null} onPlay={() => {}} />),
  );
  expect(look(container.querySelector<HTMLElement>(".acpmux-attachment-video")!)).toBe("square");
});
