// A video in the composer (Leo 2026-10-22: "also teh screen reccording preview is just a file name idk
// if we can do better maybe"): a video that goes as its path shows its poster frame, a play glyph and
// its length (m:ss), its name on hover, as an image's thumbnail does; while its poster is drawn the chip is a neutral tile; a poster
// that cannot be drawn leaves today's file chip. The poster is drawn once, from the dropped File,
// and everything it used is let go: the object URL, the video's source and listeners, the canvas.
// Image and file chips are unchanged (their markup at the base of this change).
import { afterAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

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
type Attachment = Parameters<typeof AttachmentStrip>[0]["attachments"][number];
type Pending = NonNullable<Parameters<typeof AttachmentStrip>[0]["pending"]>[number];

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const POSTER = "data:image/jpeg;base64,/9j/AA==";
const RECORDING = "Screen Recording 2026-10-22 at 21.41.07.mov";
const link = (fields: Partial<Attachment> = {}): Attachment => ({
  id: `link:/Users/you/Desktop/${RECORDING}`,
  kind: "link",
  name: RECORDING,
  mimeType: "",
  size: 0,
  path: `/Users/you/Desktop/${RECORDING}`,
  ...fields,
});

async function render(attachments: Attachment[], pending: Pending[] = []) {
  await act(async () => {
    root.render(<AttachmentStrip attachments={attachments} pending={pending} onRemove={() => {}} />);
    await Promise.resolve();
  });
}

try {
  test("a video link shows its poster frame, a play glyph and its length, its name on hover", async () => {
    await render([link({ poster: POSTER, duration: 3.04 })]);
    const chip = host.querySelector(".acpmux-attachment-video")!;
    expect(chip).not.toBeNull();
    const img = chip.querySelector(".acpmux-attachment-video-frame img")!;
    expect(img.getAttribute("src")).toBe(POSTER);
    expect(img.getAttribute("alt")).toBe(`${RECORDING} · 0:03`);
    expect(chip.querySelector(".acpmux-attachment-video-play")).not.toBeNull();
    expect(chip.querySelector(".acpmux-attachment-video-length")?.textContent).toBe("0:03");
    expect(chip.getAttribute("title")).toBe(`${RECORDING} · 0:03`);
    // Not today's file chip, and it can still be removed.
    expect(host.querySelector(".acpmux-attachment-file")).toBeNull();
    expect(chip.querySelector(".acpmux-attachment-remove")).not.toBeNull();
  });

  test("a saved copy's chip still says it goes as a path, on hover", async () => {
    await render([link({ poster: POSTER, duration: 3725, saved: true })]);
    const chip = host.querySelector(".acpmux-attachment-video")!;
    expect(chip.getAttribute("title")).toBe(`${RECORDING} · 1:02:05 · Sent as file path`);
    expect(chip.hasAttribute("data-saved")).toBe(true);
  });

  test("a poster that cannot be drawn leaves today's file chip", async () => {
    await render([link({ poster: POSTER, duration: 3 })]);
    await act(async () => {
      host.querySelector(".acpmux-attachment-video img")!.dispatchEvent(new dom.window.Event("error"));
    });
    expect(host.querySelector(".acpmux-attachment-video")).toBeNull();
    expect(host.querySelector(".acpmux-attachment-link .acpmux-attachment-link-name")?.textContent).toBe(RECORDING);
  });

  test("a video still being read is a neutral tile with a play glyph, never a spinner or its name", async () => {
    await render([], [{ id: "p1", name: RECORDING, image: false, video: true }]);
    const tile = host.querySelector(".acpmux-attachment-video.acpmux-attachment-pending")!;
    expect(tile).not.toBeNull();
    expect(tile.getAttribute("aria-busy")).toBe("true");
    expect(tile.getAttribute("aria-label")).toBe(RECORDING);
    expect(tile.querySelector("svg")).not.toBeNull();
    expect(tile.textContent).toBe("");
    expect(host.querySelector(".acpmux-attachment-file")).toBeNull();
  });

  // The markup of an image, a link and a file chip, and of a pending file, at the base of this change.
  test("image, link and file chips are unchanged", async () => {
    await render(
      [
        { id: "i", kind: "image", name: "shot.png", mimeType: "image/png", size: 1, data: "AA==" },
        link({ id: "l", name: "build-logs.zip", path: "/Users/you/Downloads/build-logs.zip" }),
        link({ id: "s", name: "repro.mov", path: "/saved/repro.mov", saved: true }),
        { id: "t", kind: "text", name: "notes.md", mimeType: "text/markdown", size: 4, text: "# hi" },
      ],
      [{ id: "p", name: "clip.zip", image: false }],
    );
    const chips = [...host.querySelectorAll(".acpmux-attachments .acpmux-attachment")].map((chip) => ({
      className: chip.getAttribute("class"),
      children: [...chip.querySelectorAll("*")].map(
        (child) => `${child.tagName.toLowerCase()}.${child.getAttribute("class") ?? ""}`,
      ),
      text: chip.textContent,
    }));
    expect(chips).toEqual([
      {
        className: "acpmux-attachment acpmux-attachment-image",
        children: ["img.", "button.acpmux-attachment-remove", "svg.", "path."],
        text: "",
      },
      {
        className: "acpmux-attachment acpmux-attachment-file acpmux-attachment-link",
        children: ["span.acpmux-attachment-link-name", "button.acpmux-attachment-remove", "svg.", "path."],
        text: "build-logs.zip",
      },
      {
        className: "acpmux-attachment acpmux-attachment-file acpmux-attachment-link",
        children: [
          "span.acpmux-attachment-link-name",
          "span.acpmux-attachment-link-note",
          "button.acpmux-attachment-remove",
          "svg.",
          "path.",
        ],
        text: "repro.movSent as file path",
      },
      {
        className: "acpmux-attachment acpmux-attachment-file",
        children: ["span.", "button.acpmux-attachment-remove", "svg.", "path."],
        text: "notes.md",
      },
      {
        className: "acpmux-attachment acpmux-attachment-file acpmux-attachment-pending",
        children: ["span."],
        text: "clip.zip",
      },
    ]);
  });

  test("the poster is drawn once from the file at a frame just after the start, and everything is let go", async () => {
    const { videoPoster } = await import("../src/agent-session/acpmux/composer/videoPoster");
    const video = dom.window.HTMLVideoElement.prototype;
    const canvas = dom.window.HTMLCanvasElement.prototype;
    const seeks: number[] = [];
    const added: string[] = [];
    const removed: string[] = [];
    const created = spyOn(URL, "createObjectURL").mockImplementation(() => "blob:http://localhost/poster");
    const revoked = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
    const add = spyOn(video, "addEventListener").mockImplementation(function (this: HTMLVideoElement, type, listener) {
      added.push(type);
      dom.window.EventTarget.prototype.addEventListener.call(this, type, listener);
    });
    const remove = spyOn(video, "removeEventListener").mockImplementation(function (
      this: HTMLVideoElement,
      type,
      listener,
    ) {
      removed.push(type);
      dom.window.EventTarget.prototype.removeEventListener.call(this, type, listener);
    });
    const load = spyOn(dom.window.HTMLMediaElement.prototype, "load").mockImplementation(() => {});
    const props = (element: HTMLVideoElement, values: Record<string, unknown>) => {
      for (const [key, value] of Object.entries(values))
        Object.defineProperty(element, key, { value, configurable: true });
    };
    const drawn: number[][] = [];
    const context = spyOn(canvas, "getContext").mockImplementation(function (this: HTMLCanvasElement) {
      return { drawImage: (_: unknown, ...box: number[]) => drawn.push(box) } as never;
    });
    const encoded = spyOn(canvas, "toDataURL").mockImplementation(() => POSTER);
    const make = spyOn(dom.window.document, "createElement");
    let element: HTMLVideoElement | undefined;
    try {
      // A 1920×1080, 3.04 s recording: metadata, then the seek's frame.
      const posting = videoPoster(new Blob([new Uint8Array(4)], { type: "video/quicktime" }));
      element = make.mock.results.find((result) => result.value instanceof dom.window.HTMLVideoElement)
        ?.value as HTMLVideoElement;
      expect(element.getAttribute("src")).toBe("blob:http://localhost/poster");
      expect(element.preload).toBe("metadata");
      expect(element.muted).toBe(true);
      props(element, { duration: 3.04, videoWidth: 1920, videoHeight: 1080 });
      Object.defineProperty(element, "currentTime", {
        configurable: true,
        set: (time: number) => {
          seeks.push(time);
          element!.dispatchEvent(new dom.window.Event("seeked"));
        },
      });
      element.dispatchEvent(new dom.window.Event("loadedmetadata"));
      expect(await posting).toEqual({ poster: POSTER, duration: 3.04 });
      expect(seeks).toEqual([0.1]);
      // Scaled to 256 px on its longest side.
      expect(drawn).toEqual([[0, 0, 256, 144]]);
      expect(created).toHaveBeenCalledTimes(1);
      expect(revoked).toHaveBeenCalledWith("blob:http://localhost/poster");
      expect(element.hasAttribute("src")).toBe(false);
      expect(load).toHaveBeenCalledTimes(1);
      expect(removed.sort()).toEqual(added.sort());
      expect(added.sort()).toEqual(["error", "loadedmetadata", "seeked"]);

      // A file the engine cannot decode: no poster, and the same cleanup.
      const failing = videoPoster(new Blob([new Uint8Array(4)]));
      const broken = make.mock.results.at(-1)?.value as HTMLVideoElement;
      broken.dispatchEvent(new dom.window.Event("error"));
      expect(await failing).toBeUndefined();
      expect(revoked).toHaveBeenCalledTimes(2);
      expect(broken.hasAttribute("src")).toBe(false);

      // One that never answers gives up at the timeout.
      expect(await videoPoster(new Blob([new Uint8Array(4)]), 10)).toBeUndefined();
      expect(revoked).toHaveBeenCalledTimes(3);
      expect(removed.length).toBe(added.length);
    } finally {
      for (const spy of [created, revoked, add, remove, load, context, encoded, make]) spy.mockRestore();
    }
  });
} finally {
  afterAll(() => {
    act(() => root.unmount());
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  });
}
