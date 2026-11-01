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

const { Activity, act, useState } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AttachmentStrip } = await import("../src/agent-session/acpmux/composer/attachmentIntake");
const { linkAttachment } = await import("../src/agent-session/acpmux/attachments");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { translate } = await import("../src/agent-session/acpmux/i18n");
const { VIDEO_INFO_DEADLINE_MS, isVideoAttachment, parseVideoInfo, useVideoInfo } =
  await import("../src/agent-session/acpmux/composer/videoAttachments");
const { keptChips } = await import("../src/agent-session/acpmux/composer/keptAttachments");

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

/// What the host heard in it (`video.transcript`).
const SPEECH = {
  segments: [{ startMs: 1_200, endMs: 4_800, text: "The sidebar jumps when I resize the window." }],
  heardMs: 42_400,
  durationMs: 42_400,
};

/// Each host call, with a way to answer it later.
type Call = { method: string; params: Record<string, unknown>; answer(value: unknown): void; fail(error: Error): void };
let calls: Call[] = [];
setChipHost(
  (method, params) =>
    new Promise((resolve, reject) => {
      calls.push({ method, params, answer: resolve, fail: reject });
    }),
);

/// The composer's staged chips and its send's wait, as Composer.tsx keeps them.
let state:
  | {
      attachments: ComposerAttachment[];
      reading: number;
      remove(id: string): void;
      add(chip: ComposerAttachment): void;
    }
  | undefined;
function Harness({ initial, local }: { initial: ComposerAttachment[]; local: boolean }) {
  const [attachments, setAttachments] = useState(initial);
  const reading = useVideoInfo(attachments, setAttachments, local);
  const remove = (id: string) => setAttachments((current) => current.filter((chip) => chip.id !== id));
  const add = (chip: ComposerAttachment) => setAttachments((current) => [...current, chip]);
  state = { attachments, reading, remove, add };
  return <AttachmentStrip attachments={attachments} onRemove={remove} />;
}

async function render(initial: ComposerAttachment[], local = true, key: string = crypto.randomUUID()) {
  calls = [];
  await act(async () => {
    root.render(<Harness key={key} initial={initial} local={local} />);
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
    expect(state?.attachments[0]?.video).toEqual(INFO);
    // Then the speech in it: the send waits for that too (within the same deadline), and nothing spins.
    expect(calls.at(-1)?.method).toBe("video.transcript");
    expect(calls.at(-1)?.params).toEqual({ src: PATH });
    expect(state?.reading).toBe(1);
    expect(host.querySelector(".acpmux-attachment-pending")).toBeNull();
    await act(async () => calls.at(-1)!.answer(SPEECH));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.transcript).toEqual(SPEECH);
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

  test("a chat's kept draft never carries a video's poster, frames or transcript: they are read again", () => {
    const read = { ...video(), video: INFO, transcript: SPEECH };
    expect(keptChips([read])).toEqual([video()]);
    expect(keptChips([video()])).toEqual([video()]);
  });

  test("a video the host cannot read stays a file chip and holds nothing", async () => {
    await render([video()]);
    await act(async () => calls[0]!.answer(undefined));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.video).toBeUndefined();
    expect(host.querySelector(".acpmux-attachment-video")).toBeNull();
    expect(host.querySelector(".acpmux-attachment-link-name")?.textContent).toBe(video().name);
  });

  test("a rejected video.info request ends the spinner and leaves the file ready to send", async () => {
    await render([video()]);
    expect(state?.reading).toBe(1);
    expect(host.querySelector(".acpmux-attachment-pending")).not.toBeNull();

    // A disconnected or outdated host may refuse the native video.info call.
    await act(async () => calls[0]!.fail(new Error("video.info unavailable")));

    expect(state?.reading).toBe(0);
    expect(state?.attachments).toHaveLength(1);
    expect(state?.attachments[0]?.video).toBeUndefined();
    expect(host.querySelector(".acpmux-attachment-pending")).toBeNull();
    expect(host.querySelector(".acpmux-attachment-link-name")?.textContent).toBe(video().name);
  });

  test("a chat on another machine asks nothing: its videos are not this Mac's", async () => {
    await render([video()], false);
    expect(calls).toEqual([]);
    expect(state?.reading).toBe(0);
    expect(host.querySelector(".acpmux-attachment-link-name")?.textContent).toBe(video().name);
  });

  test("a chat that turns out to be on this Mac reads the video it already holds", async () => {
    await render([video()], false, "same");
    expect(calls).toEqual([]);
    await act(async () => {
      root.render(<Harness key="same" initial={[]} local />);
    });
    expect(calls.map((call) => call.method)).toEqual(["video.info"]);
    expect(state?.reading).toBe(1);
  });

  test("the same video removed and added again is read again, and the first read's end leaves the second busy", async () => {
    await render([video()]);
    await act(async () => state!.remove(video().id));
    // Added again (dropped a second time): a new chip object with the same id.
    await act(async () => {
      root.render(<Harness key="readd" initial={[video()]} local />);
    });
    const [first, second] = calls.filter((call) => call.method === "video.info");
    expect(second).toBeDefined();
    expect(state?.reading).toBe(1);
    // The first composer's read ends late: the second's tile still spins.
    await act(async () => first!.answer(undefined));
    expect(state?.reading).toBe(1);
    expect(host.querySelector(".acpmux-attachment-pending")).not.toBeNull();
    await act(async () => second!.answer(INFO));
    // No speech in it: the send waits no more.
    await act(async () => calls.at(-1)!.answer({ segments: [] }));
    expect(state?.reading).toBe(0);
  });

  test("a composer that goes away ends its reads: nothing stays busy", async () => {
    await render([video()]);
    const { useVideoReading } = await import("../src/agent-session/acpmux/composer/videoAttachments");
    let busy: boolean | undefined;
    function Probe() {
      busy = useVideoReading(video().id);
      return null;
    }
    await act(async () => {
      root.render(<Probe />);
    });
    expect(busy).toBe(false);
    // Its late answer adds nothing anywhere.
    await act(async () => calls[0]!.answer(INFO));
    expect(busy).toBe(false);
  });

  test("an Activity hide retries an interrupted read, ignores its stale answer, and keeps settled metadata", async () => {
    calls = [];
    await act(async () => {
      root.render(
        <Activity mode="visible">
          <Harness initial={[video()]} local />
        </Activity>,
      );
    });
    const first = calls[0]!;
    expect(first.method).toBe("video.info");

    await act(async () => {
      root.render(
        <Activity mode="hidden">
          <Harness initial={[video()]} local />
        </Activity>,
      );
    });
    // The interrupted chip remains pending for submission, even before its effect reconnects.
    expect(state?.reading).toBe(1);
    expect(calls.filter((call) => call.method === "video.info")).toHaveLength(1);

    await act(async () => {
      root.render(
        <Activity mode="visible">
          <Harness initial={[video()]} local />
        </Activity>,
      );
    });
    const reads = calls.filter((call) => call.method === "video.info");
    expect(reads).toHaveLength(2);
    expect(state?.reading).toBe(1);

    // The hidden Activity's response must not settle or annotate the replacement read.
    await act(async () => first.answer(INFO));
    expect(state?.attachments[0]?.video).toBeUndefined();
    expect(state?.reading).toBe(1);
    await act(async () => reads[1]!.answer(INFO));
    expect(state?.attachments[0]?.video).toEqual(INFO);
    await act(async () => calls.at(-1)!.answer(SPEECH));
    expect(state?.reading).toBe(0);

    // A settled chip is still marked complete across another hide/reveal and is not re-read.
    await act(async () => {
      root.render(
        <Activity mode="hidden">
          <Harness initial={[state!.attachments[0]!]} local />
        </Activity>,
      );
    });
    await act(async () => {
      root.render(
        <Activity mode="visible">
          <Harness initial={[state!.attachments[0]!]} local />
        </Activity>,
      );
    });
    expect(calls.filter((call) => call.method === "video.info")).toHaveLength(2);
    expect(state?.attachments[0]?.video).toEqual(INFO);
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

  test("a chip removed and added again in the same composer takes only its own read's answer", async () => {
    await render([video()], true, "same-composer");
    await act(async () => state!.remove(video().id));
    await act(async () => state!.add(video()));
    const [first, second] = calls.filter((call) => call.method === "video.info");
    expect(second).toBeDefined();
    expect(state?.reading).toBe(1);
    // The first read answers late, with another poster: the new chip does not take it.
    await act(async () => first!.answer({ ...INFO, durationMs: 1_000, poster: "data:image/jpeg;base64,old" }));
    expect(state?.attachments[0]?.video).toBeUndefined();
    expect(state?.reading).toBe(1);
    await act(async () => second!.answer(INFO));
    expect(state?.attachments[0]?.video).toEqual(INFO);
    await act(async () => calls.at(-1)!.fail(new Error("video.transcript unavailable")));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.transcript).toBeUndefined();
  });

  test("a chat that turns remote while its video is read ends the read: a late answer adds nothing", async () => {
    await render([video()], true, "turns-remote");
    expect(state?.reading).toBe(1);
    await act(async () => {
      root.render(<Harness key="turns-remote" initial={[]} local={false} />);
    });
    expect(state?.reading).toBe(0);
    await act(async () => calls[0]!.answer(INFO));
    expect(state?.attachments[0]?.video).toBeUndefined();
    // Back on this Mac, the chip is read again.
    await act(async () => {
      root.render(<Harness key="turns-remote" initial={[]} local />);
    });
    expect(calls.filter((call) => call.method === "video.info").length).toBe(2);
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
  test("a video's speech is asked once and goes on its chip", async () => {
    await render([video()]);
    await act(async () => calls[0]!.answer(INFO));
    const listen = calls.at(-1)!;
    expect(listen.method).toBe("video.transcript");
    expect(state?.reading).toBe(1);
    await act(async () => listen.answer(SPEECH));
    expect(state?.reading).toBe(0);
    // Read once: a later render asks nothing again.
    await act(async () => state!.add({ ...linkAttachment("/tmp/other.zip", false), mimeType: "application/zip" }));
    expect(calls.filter((call) => call.method === "video.transcript")).toHaveLength(1);
    expect(state?.attachments[0]?.transcript).toEqual(SPEECH);
  });

  test("removing a video while its speech is heard ends the wait, and a late answer adds nothing", async () => {
    await render([video()]);
    await act(async () => calls[0]!.answer(INFO));
    const listen = calls.at(-1)!;
    expect(state?.reading).toBe(1);
    await act(async () => state!.remove(video().id));
    expect(state?.reading).toBe(0);
    await act(async () => listen.answer(SPEECH));
    expect(state?.attachments).toEqual([]);
  });

  test("a chat that turns remote while its video's speech is heard ends that wait too", async () => {
    await render([video()], true, "hears-remote");
    await act(async () => calls[0]!.answer(INFO));
    expect(state?.reading).toBe(1);
    await act(async () => {
      root.render(<Harness key="hears-remote" initial={[]} local={false} />);
    });
    expect(state?.reading).toBe(0);
    await act(async () => calls.at(-1)!.answer(SPEECH));
    expect(state?.attachments[0]?.transcript).toBeUndefined();
  });

  test("the answer's probes pick the frames: the host decodes them, they replace the four, and the send waits", async () => {
    // Black, then white from 20 s: one cut, which gets a frame of its own, marked.
    const cells = (gray: number) => btoa(String.fromCharCode(...new Uint8Array(24 * 24).fill(gray)));
    const probes = Array.from({ length: 48 }, (_, index) => {
      const atMs = Math.round(((index + 0.5) * INFO.durationMs) / 48);
      return { atMs, cells: cells(atMs < 20_000 ? 0 : 255) };
    });
    await render([video()]);
    await act(async () => calls[0]!.answer({ ...INFO, probes }));
    // The poster shows at once; the send still waits for the picked frames.
    expect(host.querySelector(".acpmux-attachment-video img")?.getAttribute("src")).toBe(POSTER);
    expect(host.querySelector(".acpmux-attachment-pending")).toBeNull();
    expect(state?.reading).toBe(1);
    const asked = calls.find((call) => call.method === "video.frames")!;
    expect(asked.params.src).toBe(PATH);
    const times = asked.params.times as number[];
    expect(times).toHaveLength(16);
    const cut = probes.find((probe) => probe.atMs >= 20_000)!.atMs;
    expect(times).toContain(cut);
    await act(async () => asked.answer({ frames: times.map((atMs) => ({ atMs, data: "/9j/BB==" })) }));
    // The speech is still heard.
    expect(state?.reading).toBe(1);
    await act(async () => calls.find((call) => call.method === "video.transcript")!.answer(SPEECH));
    expect(state?.reading).toBe(0);
    const frames = state?.attachments[0]?.video?.frames ?? [];
    expect(state?.attachments[0]?.video?.picked).toBe(true);
    expect(frames.map((frame) => frame.atMs)).toEqual(times);
    expect(frames.filter((frame) => frame.scene).map((frame) => frame.atMs)).toEqual([cut]);
    // Each asked once, and the speech went on the chip whose frames were replaced.
    expect(calls.filter((call) => call.method === "video.frames")).toHaveLength(1);
    expect(calls.filter((call) => call.method === "video.transcript")).toHaveLength(1);
    expect(state?.attachments[0]?.transcript).toEqual(SPEECH);
  });

  test("speech heard before the picked frames come stays on the chip when they replace the four", async () => {
    const cells = btoa(String.fromCharCode(...new Uint8Array(24 * 24).fill(9)));
    const probes = [0, 1, 2, 3].map((index) => ({ atMs: 1000 + index * 5000, cells }));
    await render([video()]);
    await act(async () => calls[0]!.answer({ ...INFO, probes }));
    await act(async () => calls.find((call) => call.method === "video.transcript")!.answer(SPEECH));
    expect(state?.reading).toBe(1);
    const asked = calls.find((call) => call.method === "video.frames")!;
    const times = asked.params.times as number[];
    await act(async () => asked.answer({ frames: times.map((atMs) => ({ atMs, data: "/9j/CC==" })) }));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.video?.picked).toBe(true);
    expect(state?.attachments[0]?.transcript).toEqual(SPEECH);
    expect(calls.filter((call) => call.method === "video.transcript")).toHaveLength(1);
  });

  test("an older host that has no video.frames keeps the answer's four frames, and the send goes", async () => {
    const still = btoa("\u0000\u0000\u0000\u0000");
    const probes = [0, 1, 2].map((index) => ({ atMs: 1000 + index * 1000, cells: still }));
    await render([video()]);
    await act(async () => calls[0]!.answer({ ...INFO, probes }));
    expect(state?.reading).toBe(1);
    await act(async () => calls.find((call) => call.method === "video.frames")!.fail(new Error("unknown method video.frames")));
    await act(async () => calls.find((call) => call.method === "video.transcript")!.answer(SPEECH));
    expect(state?.reading).toBe(0);
    expect(state?.attachments[0]?.video?.frames).toEqual(INFO.frames);
    expect(state?.attachments[0]?.video?.picked).toBeUndefined();
  });

  test("an answer without probes asks for no picked frames", async () => {
    await render([video()]);
    await act(async () => calls[0]!.answer(INFO));
    expect(calls.map((call) => call.method)).toEqual(["video.info", "video.transcript"]);
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
