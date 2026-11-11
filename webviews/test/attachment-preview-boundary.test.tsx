// Leo, 2026-11-11: "i tried uploading this video to my nightly app and it just made the screen blank"
// (a macOS screen recording, 2112x720 H.264, named "Screen Recording 2026-11-10 at 4.21.16 PM.mov"
// with a narrow no-break space, U+202F, before "PM"). An attachment's preview that throws while it
// draws must never blank the prompt or the pane: that one chip falls back to the file's plain chip,
// its name and its ×, and the other chips and the page stay (composer/AttachmentPreviewBoundary.tsx).
// The matrix: videos (H.264 and HEVC .mov, .mp4, odd sizes like 2112x720 and 7x4320), a large image,
// and file names with U+202F, spaces and other unicode; each draws its own preview, and each one made
// to throw (a host answer whose poster or bytes cannot be read) is its file chip. A sent video's tile
// falls back the same way.
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

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
const { SentVideoTile } = await import("../src/agent-session/acpmux/conversation/SentVideoTile");
const { linkAttachment } = await import("../src/agent-session/acpmux/attachments");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
// Every host call is refused: nothing here depends on the host answering.
setChipHost(() => Promise.reject(new Error("no host in this test")));
// React reports a caught render error on the console; the boundary logs its own line too.
const quiet = console.error;
const logged: unknown[][] = [];
console.error = (...args: unknown[]) => void logged.push(args);

const NNBSP = "\u202F";
const POSTER = "data:image/jpeg;base64,/9j/AA==";

type Case = { name: string; type: string; width: number; height: number; durationMs: number };
const VIDEOS: Case[] = [
  // Leo's own recording: H.264, 2112x720, 8.9 s, U+202F before PM.
  { name: `Screen Recording 2026-11-10 at 4.21.16${NNBSP}PM.mov`, type: "video/quicktime", width: 2112, height: 720, durationMs: 8_900 },
  // A Retina screen recording in HEVC.
  { name: `Screen Recording 2026-11-10 at 4.04.20${NNBSP}PM (2).mov`, type: "video/quicktime", width: 3840, height: 2160, durationMs: 14_200 },
  // An odd size, and a name with spaces and other scripts.
  { name: "屏幕录制 2026-11-10 下午 4.21.16 – café résumé.mp4", type: "video/mp4", width: 7, height: 4320, durationMs: 1_000 },
  { name: "clip with  two  spaces.m4v", type: "video/x-m4v", width: 2112, height: 720, durationMs: 600_000 },
];

function videoChip(spec: Case, id: string): ComposerAttachment {
  return {
    ...linkAttachment(`/Users/leo/Desktop/${spec.name}`, false),
    id,
    mimeType: spec.type,
    size: 2_377_732,
    video: { durationMs: spec.durationMs, width: spec.width, height: spec.height, poster: POSTER, frames: [] },
  };
}

/// A large screenshot (8.5 MB) staged as an image chip.
function imageChip(id: string): ComposerAttachment {
  return {
    id,
    kind: "image",
    name: `Screenshot 2026-11-10 at 4.18.20${NNBSP}PM (2).png`,
    mimeType: "image/png",
    size: 8_543_517,
    data: "iVBORw0KGgo=",
  };
}

/// `chip` whose `key` cannot be read: what a host answer the page did not expect does to a draw.
function poisoned<T extends object>(chip: T, key: string): T {
  return new Proxy(chip, {
    get(target, prop, receiver) {
      if (prop === key) throw new Error(`unreadable ${key}`);
      return Reflect.get(target, prop, receiver);
    },
  });
}

let removed: string[] = [];
async function strip(attachments: ComposerAttachment[]) {
  removed = [];
  await act(async () => {
    root.render(<AttachmentStrip attachments={attachments} onRemove={(id) => removed.push(id)} />);
  });
}

const failedChips = () => [...host.querySelectorAll('[data-preview-failed="true"]')];

try {
  test("every video, a large image and unicode names draw their own previews", async () => {
    const chips = [...VIDEOS.map((spec, index) => videoChip(spec, `v${index}`)), imageChip("img")];
    await strip(chips);
    expect(host.querySelectorAll(".acpmux-attachment-video").length).toBe(VIDEOS.length);
    expect(host.querySelectorAll(".acpmux-attachment-video img").length).toBe(VIDEOS.length);
    expect(host.querySelector(".acpmux-attachment-image img")).not.toBeNull();
    expect(failedChips()).toEqual([]);
  });

  test("a video whose preview throws is its file chip; the strip and its other chips stay", async () => {
    const leo = VIDEOS[0]!;
    const broken = poisoned(videoChip(leo, "leo"), "video");
    const others = [videoChip(VIDEOS[1]!, "hevc"), imageChip("img")];
    await strip([broken, ...others]);
    const failed = failedChips();
    expect(failed.length).toBe(1);
    // Its whole name, U+202F kept, in the chip's tooltip and in its text.
    expect(failed[0]!.getAttribute("title")).toBe(`/Users/leo/Desktop/${leo.name}`);
    expect(failed[0]!.textContent?.replace(/\s+/g, "")).toContain("4.21.16");
    expect(failed[0]!.textContent).toContain(NNBSP);
    // The rest of the strip still draws.
    expect(host.querySelectorAll(".acpmux-attachment-video img").length).toBe(1);
    expect(host.querySelector(".acpmux-attachment-image img")).not.toBeNull();
    // Its × still removes it.
    const remove = failed[0]!.querySelector<HTMLButtonElement>(".acpmux-attachment-remove");
    await act(async () => remove?.click());
    expect(removed).toEqual(["leo"]);
    expect(logged.some((args) => String(args[0]).includes("attachment preview failed"))).toBe(true);
  });

  test("each kind made to throw falls back on its own, with any name", async () => {
    const chips = [
      ...VIDEOS.map((spec, index) => poisoned(videoChip(spec, `v${index}`), "video")),
      poisoned(imageChip("img"), "data"),
    ];
    await strip(chips);
    const failed = failedChips();
    expect(failed.length).toBe(chips.length);
    for (const spec of VIDEOS) expect(failed.some((chip) => chip.getAttribute("title")?.endsWith(spec.name))).toBe(true);
  });

  test("a new attachment object tries the preview again", async () => {
    const chip = videoChip(VIDEOS[0]!, "leo");
    await strip([poisoned(chip, "video")]);
    expect(failedChips().length).toBe(1);
    await strip([{ ...chip }]);
    expect(failedChips()).toEqual([]);
    expect(host.querySelector(".acpmux-attachment-video img")).not.toBeNull();
  });

  test("a sent video whose tile throws is its file chip, and the message stays", async () => {
    const name = VIDEOS[0]!.name;
    const sent = poisoned({ name, path: `/Users/leo/Desktop/${name}`, length: "0:09", width: 2112, height: 720 }, "poster");
    await act(async () => {
      root.render(
        <div className="message">
          <p>look at this</p>
          <SentVideoTile video={sent} width={240} height={82} />
        </div>,
      );
    });
    expect(host.querySelector(".message p")?.textContent).toBe("look at this");
    const failed = failedChips();
    expect(failed.length).toBe(1);
    expect(failed[0]!.textContent).toContain(NNBSP);
  });
} finally {
  afterAll(() => {
    console.error = quiet;
    setChipHost(undefined);
    act(() => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
