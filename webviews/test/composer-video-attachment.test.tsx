// Leo, 2026-10-25: "also why dont we have previews of videos we should ... oh attaching a video froze
// the composer". A video the composer holds as its path (dropped, pasted or chosen in a chat on this
// Mac) shows its poster and length once the host read them (`video.info`, never decoded in the page),
// and a click plays it (`video.quickLook`). A send waits for that read a few seconds at most; a chip
// the host cannot read, one in a chat on another machine, and one removed meanwhile wait for nothing.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
const { linkAttachment } = await import("../src/agent-session/acpmux/attachments");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { VIDEO_INFO_DEADLINE_MS, isVideoAttachment, parseVideoInfo, useVideoInfo } =
  await import("../src/agent-session/acpmux/composer/videoAttachments");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

const PATH = "/Users/dev/Desktop/Screen Recording 2026-10-25 at 10.42.13.mov";
const POSTER = "data:image/jpeg;base64,/9j/AA==";
const INFO = {
  durationMs: 42_400,
  width: 1920,
  height: 1080,
  poster: POSTER,
  frames: [5300, 15900, 26500, 37100].map((atMs) => ({ atMs, data: "/9j/AA==" })),
};

/// Each host call, with a way to answer it later.
type Call = { method: string; params: Record<string, unknown>; answer(value: unknown): void };
let calls: Call[] = [];
setChipHost(
  (method, params) =>
    new Promise((resolve) => {
      calls.push({ method, params, answer: resolve });
    }),
);

/// The composer's staged chips and its send's wait, as Composer.tsx keeps them.
let state: { attachments: ComposerAttachment[]; reading: number; remove(id: string): void } | undefined;
function Harness({ initial, local }: { initial: ComposerAttachment[]; local: boolean }) {
  const [attachments, setAttachments] = useState(initial);
  const reading = useVideoInfo(attachments, setAttachments, () => local);
  const remove = (id: string) => setAttachments((current) => current.filter((chip) => chip.id !== id));
  state = { attachments, reading, remove };
  return <AttachmentStrip attachments={attachments} onRemove={remove} />;
}

async function render(initial: ComposerAttachment[], local = true) {
  calls = [];
  await act(async () => {
    root.render(<Harness key={crypto.randomUUID()} initial={initial} local={local} />);
  });
}

const video = () => ({ ...linkAttachment(PATH, false), mimeType: "video/quicktime", size: 48_000_000 });

try {
  test("a video link is a movie by its name; the chooser's chips have no type", () => {
    expect(isVideoAttachment(video())).toBe(true);
    expect(isVideoAttachment(linkAttachment("/tmp/demo.MP4", false))).toBe(true);
    expect(isVideoAttachment(linkAttachment("/tmp/clip.m4v", false))).toBe(true);
    expect(isVideoAttachment(linkAttachment("/tmp/build.zip", false))).toBe(false);
    expect(isVideoAttachment(linkAttachment("/tmp/movies.mov", true))).toBe(true);
    expect(isVideoAttachment({ ...video(), kind: "image" })).toBe(false);
  });

  test("the host's answer is checked before it goes on the chip", () => {
    expect(parseVideoInfo(INFO)).toEqual(INFO);
    expect(parseVideoInfo({ ...INFO, poster: "https://example.com/x.jpg" })).toBeUndefined();
    expect(parseVideoInfo({ ...INFO, durationMs: 0 })).toBeUndefined();
    expect(parseVideoInfo(null)).toBeUndefined();
    expect(
      parseVideoInfo({ ...INFO, frames: [...INFO.frames, { atMs: -1, data: "x" }, { atMs: 1 }, "x"] })?.frames,
    ).toEqual(INFO.frames);
  });

  test("a dropped video spins in its tile, then shows its poster and length, and a click plays it", async () => {
    await render([video()]);
    expect(calls.map(({ method, params }) => [method, params])).toEqual([["video.info", { src: PATH }]]);
    // While the host reads it: a busy tile, and the send waits.
    const busy = host.querySelector(".acpmux-attachment-image.acpmux-attachment-pending");
    expect(busy?.getAttribute("aria-busy")).toBe("true");
    expect(state?.reading).toBe(1);

    await act(async () => calls[0]!.answer(INFO));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.video).toEqual(INFO);
    const tile = host.querySelector(".acpmux-attachment-video")!;
    expect(tile.getAttribute("title")).toBe(video().name);
    expect(tile.querySelector("img")?.getAttribute("src")).toBe(POSTER);
    expect(tile.querySelector(".acpmux-attachment-video-length")?.textContent).toBe("0:42");
    const play = tile.querySelector(".acpmux-attachment-video-open") as HTMLElement;
    expect(play.getAttribute("aria-label")).toBe(
      translate("composer.playVideo", { name: video().name, length: "0:42" }),
    );
    // Its × still removes it.
    expect(tile.querySelector(".acpmux-attachment-remove")).not.toBeNull();

    await act(async () => play.click());
    expect(calls.at(-1)?.method).toBe("video.quickLook");
    expect(calls.at(-1)?.params).toEqual({ src: PATH });
    // Read once: a later render asks nothing again.
    expect(calls.filter((call) => call.method === "video.info").length).toBe(1);
  });

  test("a video the host cannot read stays a file chip and holds nothing", async () => {
    await render([video()]);
    await act(async () => calls[0]!.answer(undefined));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.video).toBeUndefined();
    expect(host.querySelector(".acpmux-attachment-video")).toBeNull();
    expect(host.querySelector(".acpmux-attachment-link-name")?.textContent).toBe(video().name);
  });

  test("a chat on another machine asks nothing: its videos are not this Mac's", async () => {
    await render([video()], false);
    expect(calls).toEqual([]);
    expect(state?.reading).toBe(0);
    expect(host.querySelector(".acpmux-attachment-link-name")?.textContent).toBe(video().name);
  });

  test("other files are not read", async () => {
    await render([{ ...linkAttachment("/Users/dev/Downloads/build-logs.zip", false), mimeType: "application/zip" }]);
    expect(calls).toEqual([]);
  });

  test("removing a video while it is read stops the send's wait", async () => {
    await render([video()]);
    expect(state?.reading).toBe(1);
    await act(async () => state!.remove(video().id));
    expect(state?.reading).toBe(0);
    // Its late answer adds nothing back.
    await act(async () => calls[0]!.answer(INFO));
    expect(state?.attachments).toEqual([]);
  });

  test("a read that takes past the deadline lets the send go; a late answer still draws the poster", async () => {
    // The deadline's timer, run by hand (no wall-clock wait).
    const timers: { ms: number; run(): void }[] = [];
    const realSetTimeout = globalThis.setTimeout;
    globalThis.setTimeout = ((run: () => void, ms: number) => {
      timers.push({ ms, run });
      return timers.length as unknown as ReturnType<typeof setTimeout>;
    }) as typeof setTimeout;
    try {
      await render([video()]);
    } finally {
      globalThis.setTimeout = realSetTimeout;
    }
    const deadline = timers.find((timer) => timer.ms === VIDEO_INFO_DEADLINE_MS);
    expect(VIDEO_INFO_DEADLINE_MS).toBeLessThanOrEqual(5_000);
    expect(state?.reading).toBe(1);
    await act(async () => deadline!.run());
    expect(state?.reading).toBe(0);
    await act(async () => calls[0]!.answer(INFO));
    expect(host.querySelector(".acpmux-attachment-video img")?.getAttribute("src")).toBe(POSTER);
  });
} finally {
  afterAll(() => {
    setChipHost(undefined);
    act(() => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
