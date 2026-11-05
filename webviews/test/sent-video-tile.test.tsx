// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-10-25: "also why dont we have previews of videos we should". A video sent with its
// frames (composer/videoPrompt.ts) showed nothing in its bubble: the frames and their note are left
// out (#30893) and the video's link was left out as a file (#25872). Now it is its poster (its first
// frame), a play glyph and its length among the prompt's images, and a click plays it, before
// acpmux's echo, after it and in a prompt whose attachments were placed in its text.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
const { linkAttachment } = await import("../src/agent-session/acpmux/attachments");

const PATH = "/Users/dev/Library/Application Support/cmux/Chat Uploads/0190a000-upload/0/screen-demo.mp4";
const URI = `file://${encodeURI(PATH)}`;
const NOTE = "Frames from the video screen-demo.mp4 (0:16, 1920×1080), in order, at: 0:02.0, 0:06.0.";
const FRAME_IDS = ["b".repeat(64), "c".repeat(64)];
const SHOT = { id: "a".repeat(64), mimeType: "image/png", name: "Screenshot.png" };
const frames = [
  { id: FRAME_IDS[0]!, mimeType: "image/jpeg", name: "screen-demo.mp4 frame at 0:02.0" },
  { id: FRAME_IDS[1]!, mimeType: "image/jpeg", name: "screen-demo.mp4 frame at 0:06.0" },
];
const labels = "screen-demo.mp4 frame at 0:02.0\nscreen-demo.mp4 frame at 0:06.0";

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const calls: { method: string; params: Record<string, unknown> }[] = [];
setChipHost(async (method, params) => {
  calls.push({ method, params });
  return null;
});
const read: string[] = [];
const actions = {
  promptImage: async (id: string) => {
    read.push(id);
    return `data:image/jpeg;base64,${id.slice(0, 4)}`;
  },
};

async function render(row: AcpmuxRow) {
  read.length = 0;
  await act(async () => {
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={row} text={row.text ?? ""} />
      </TurnActionsContext.Provider>,
    );
  });
  await act(async () => {
    await Promise.resolve();
  });
}

/// What the video tile draws: its poster's source, its length, its name; and the row's other media.
function shown() {
  const tile = host.querySelector(".cv-user__video") as HTMLElement | null;
  return {
    tile,
    poster: tile?.querySelector("img")?.getAttribute("src"),
    length: tile?.querySelector(".cv-user__video-length")?.textContent,
    title: tile?.getAttribute("title"),
    images: [...host.querySelectorAll("img")]
      .filter((img) => !tile?.contains(img))
      .map((img) => img.getAttribute("src")),
    files: [...host.querySelectorAll(".cv-user__files, .cv-user__inline-file")].map((node) => node.textContent),
    bubble: host.querySelector(".cv-user__bubble")?.textContent,
  };
}

try {
  test("acpmux's record of a prompt with a video draws its poster and length, never a file chip, and plays on click", async () => {
    await render({
      id: "user-1",
      version: 1,
      at: 0,
      kind: "user",
      text: `what goes wrong?\n\n${NOTE}\n${labels}`,
      images: [SHOT, ...frames],
      inlineParts: [
        { kind: "text", text: "what goes wrong?" },
        { kind: "file", name: "screen-demo.mp4", uri: URI },
        { kind: "text", text: NOTE },
        { kind: "text", text: frames[0]!.name },
        { kind: "image", ...frames[0]! },
        { kind: "text", text: frames[1]!.name },
        { kind: "image", ...frames[1]! },
      ],
    } as AcpmuxRow);
    const view = shown();
    expect(view.tile).not.toBeNull();
    // Its first frame is its poster; the other frame is not drawn, the person's screenshot is.
    expect(view.poster).toBe("data:image/jpeg;base64,bbbb");
    expect(view.images).toEqual(["data:image/jpeg;base64,aaaa"]);
    expect(read.sort()).toEqual([SHOT.id, FRAME_IDS[0]!]);
    expect(view.length).toBe("0:16");
    expect(view.title).toBe("screen-demo.mp4");
    expect(view.files.join("")).not.toContain("screen-demo.mp4");
    expect(view.bubble).toBe("what goes wrong?");
    // Video first in the row, as the composer's strip had it.
    expect(host.querySelector(".cv-user__images")?.firstElementChild?.className).toBe("cv-user__video");
    // A host that grants no stream: Quick Look plays it.
    await act(async () => view.tile!.click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(calls.slice(-2)).toEqual([
      { method: "media.load", params: { src: PATH } },
      { method: "video.quickLook", params: { src: PATH } },
    ]);
  });

  test("before acpmux's echo the pane's own row draws the tile from the composer's chip", async () => {
    await render({
      id: "user-2",
      version: 1,
      at: 0,
      kind: "user",
      text: `look\n\n${NOTE}\n${labels}`,
      images: frames,
      retryAttachments: [{ ...linkAttachment(PATH, false), mimeType: "video/mp4", size: 9 }],
    } as AcpmuxRow);
    const view = shown();
    expect(view.poster).toBe("data:image/jpeg;base64,bbbb");
    expect(view.length).toBe("0:16");
    expect(view.images).toEqual([]);
  });

  test("a video placed in the text is its tile where it was put", async () => {
    await render({
      id: "user-3",
      version: 1,
      at: 0,
      kind: "user",
      text: `before\n${NOTE}\n${labels}\nafter`,
      images: frames,
      inlineParts: [
        { kind: "text", text: "before" },
        { kind: "file", name: "screen-demo.mp4", uri: URI, placed: true },
        { kind: "text", text: NOTE },
        { kind: "text", text: frames[0]!.name },
        { kind: "image", ...frames[0]! },
        { kind: "text", text: frames[1]!.name },
        { kind: "image", ...frames[1]! },
        { kind: "text", text: "after" },
      ],
    } as AcpmuxRow);
    const view = shown();
    expect(view.tile?.closest(".cv-user__bubble")).not.toBeNull();
    expect(view.poster).toBe("data:image/jpeg;base64,bbbb");
    expect(view.files).toEqual([]);
  });

  test("a video sent without frames has no note: it stays the file chip it was", async () => {
    await render({
      id: "user-4",
      version: 1,
      at: 0,
      kind: "user",
      text: "look",
      inlineParts: [
        { kind: "text", text: "look" },
        { kind: "file", name: "screen-demo.mp4", uri: URI },
      ],
    } as AcpmuxRow);
    const view = shown();
    expect(view.tile).toBeNull();
    expect(view.files.join("")).toContain("screen-demo.mp4");
  });

  test("a person's own line that only reads like a note, with no frame or link, draws no tile", async () => {
    await render({ id: "user-5", version: 1, at: 0, kind: "user", text: NOTE } as AcpmuxRow);
    expect(shown().tile).toBeNull();
    expect(shown().bubble).toBe(NOTE);
  });
  // Leo, 2026-11-02: "this i can't play a video preview inside cmux next? i feel like i should be able to".
  test("a click on a sent video's ▶ plays it in place: the reply's player, with controls, on the host's streamed URL", async () => {
    const path = "/Users/dev/Desktop/inline-demo.mp4";
    const src = "cmux-agent://pane/__media/feedfacefeedface.mp4";
    const note = "Frames from the video inline-demo.mp4 (0:16, 1920×1080), in order, at: 0:02.0, 0:06.0.";
    const frame = { id: "d".repeat(64), mimeType: "image/jpeg", name: "inline-demo.mp4 frame at 0:02.0" };
    const played: HTMLMediaElement[] = [];
    const proto = dom.window.HTMLMediaElement.prototype;
    const original = proto.play;
    proto.play = function (this: HTMLMediaElement) {
      played.push(this);
      return Promise.resolve();
    };
    setChipHost(async (method, params) => {
      calls.push({ method, params });
      return method === "media.load" && params.src === path ? { src } : null;
    });
    try {
      await render({
        id: "user-6",
        version: 1,
        at: 0,
        kind: "user",
        text: `play it\n\n${note}\n${frame.name}`,
        images: [frame],
        inlineParts: [
          { kind: "text", text: "play it" },
          { kind: "file", name: "inline-demo.mp4", uri: `file://${path}` },
          { kind: "text", text: note },
          { kind: "text", text: frame.name },
          { kind: "image", ...frame },
        ],
      } as AcpmuxRow);
      const tile = host.querySelector<HTMLElement>(".cv-user__video");
      expect(tile?.querySelector(".cv-user__video-length")?.textContent).toBe("0:16");
      await act(async () => tile!.click());
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
      const player = host.querySelector<HTMLVideoElement>(".cv-user__video-player video");
      expect(player).not.toBeNull();
      expect(player!.getAttribute("src")).toBe(src);
      expect(player!.hasAttribute("controls")).toBe(true);
      expect(player!.muted).toBe(false);
      expect(played).toEqual([player!]);
      expect(host.querySelector(".cv-user__video")).toBeNull();
      expect(calls.some((call) => call.method === "video.quickLook" && call.params.src === path)).toBe(false);
      // Expand and Open in tab stay with it.
      expect(host.querySelector(".cv-user__video-player .cv-media__expand")).not.toBeNull();
    } finally {
      proto.play = original;
    }
  });

  /// A sent video placed in its prompt, on a host that grants `src` for it.
  async function grantedVideo(id: string, path: string, src: string) {
    const name = path.split("/").pop()!;
    const note = `Frames from the video ${name} (0:10, 1576×1114), in order, at: 0:02.0.`;
    const frame = { id: "e".repeat(64), mimeType: "image/jpeg", name: `${name} frame at 0:02.0` };
    setChipHost(async (method, params) => {
      calls.push({ method, params });
      return method === "media.load" && params.src === path ? { src } : null;
    });
    await render({
      id,
      version: 1,
      at: 0,
      kind: "user",
      text: `look\n\n${note}\n${frame.name}`,
      images: [frame],
      inlineParts: [
        { kind: "text", text: "look" },
        { kind: "file", name, uri: `file://${encodeURI(path)}` },
        { kind: "text", text: note },
        { kind: "text", text: frame.name },
        { kind: "image", ...frame },
      ],
    } as AcpmuxRow);
    return host.querySelector<HTMLElement>(".cv-user__video")!;
  }
  const settle = () =>
    act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });

  // Leo, 2026-11-03: "i can neither preview a vid in place nor have it pop up anymore". The host
  // granted the recording, the pane's player could not play it, and the tile came back with
  // nothing shown (#32697): every click did nothing.
  test("a granted video the pane's player cannot play opens in Quick Look on the same click", async () => {
    const path = "/Users/dev/Desktop/Screen Recording 2026-11-03 at 6.32.47 PM.mov";
    const tile = await grantedVideo("user-7", path, "cmux-agent://pane/__media/0badc0de0badc0de.mov");
    const proto = dom.window.HTMLMediaElement.prototype;
    const original = proto.play;
    proto.play = () => Promise.resolve();
    try {
      calls.length = 0;
      await act(async () => tile.click());
      await settle();
      const player = host.querySelector<HTMLVideoElement>(".cv-user__video-player video");
      expect(player).not.toBeNull();
      await act(async () => {
        player!.dispatchEvent(new dom.window.Event("error"));
      });
      expect(calls.map((call) => call.method)).toEqual(["media.load", "video.quickLook"]);
      expect(calls[1]!.params).toEqual({ src: path });
      // The tile is back, ready for the next click.
      expect(host.querySelector(".cv-user__video")).not.toBeNull();
      expect(host.querySelector(".cv-user__video-player")).toBeNull();
    } finally {
      proto.play = original;
    }
  });

  test("a double-click on a sent video opens it large over the pane, playing, and Close brings the tile back", async () => {
    const path = "/Users/dev/Desktop/expand-demo.mov";
    const src = "cmux-agent://pane/__media/abcdefabcdefabcd.mov";
    const tile = await grantedVideo("user-8", path, src);
    const played: HTMLMediaElement[] = [];
    const proto = dom.window.HTMLMediaElement.prototype;
    const original = proto.play;
    proto.play = function (this: HTMLMediaElement) {
      played.push(this);
      return Promise.resolve();
    };
    try {
      await act(async () => {
        tile.dispatchEvent(new dom.window.MouseEvent("dblclick", { bubbles: true }));
      });
      await settle();
      const viewer = dom.window.document.querySelector<HTMLVideoElement>(".acpmux-image-viewer video");
      expect(viewer).not.toBeNull();
      expect(viewer!.getAttribute("src")).toBe(src);
      expect(viewer!.hasAttribute("controls")).toBe(true);
      expect(played).toEqual([viewer!]);
      // The poster stays in the bubble behind it; nothing plays in place at the same time.
      expect(host.querySelector(".cv-user__video")).not.toBeNull();
      expect(host.querySelector(".cv-user__video-player")).toBeNull();
      const close = dom.window.document.querySelector<HTMLElement>(".acpmux-image-viewer-action")!;
      await act(async () => close.click());
      expect(dom.window.document.querySelector(".acpmux-image-viewer")).toBeNull();
      expect(host.querySelector(".cv-user__video")).not.toBeNull();
    } finally {
      proto.play = original;
    }
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
