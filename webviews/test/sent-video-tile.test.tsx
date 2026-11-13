// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-10-25: "also why dont we have previews of videos we should". A video sent with its
// frames (composer/videoPrompt.ts) showed nothing in its bubble: the frames and their note are left
// out (#30893) and the video's link was left out as a file (#25872). Now it is its poster (its first
// frame), a play glyph and its length among the prompt's images, and a click plays it, before
// acpmux's echo, after it and in a prompt whose attachments were placed in its text.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
const { linkAttachment, promptText } = await import("../src/agent-session/acpmux/attachments");

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

  // Leo, 2026-11-06: "how come this didn't give a preview and only has file name?" A video the
  // agent got no frames for (its read failed or timed out, a remote chat, an agent that takes no
  // images) is still a video: its tile, square, never a file chip.
  test("a video sent without frames is its tile where it was put, square, never a file chip", async () => {
    await render({
      id: "user-4",
      version: 1,
      at: 0,
      kind: "user",
      text: "look",
      inlineParts: [
        { kind: "file", name: "screen-demo.mov", uri: URI.replace(".mp4", ".mov") },
        { kind: "text", text: "look" },
      ],
    } as AcpmuxRow);
    const view = shown();
    expect(view.tile).not.toBeNull();
    expect(view.tile?.closest(".cv-user__bubble")).not.toBeNull();
    expect(view.tile?.style.width).toBe("120px");
    expect(view.title).toBe("screen-demo.mov");
    expect(view.files.join("")).not.toContain("screen-demo.mov");
    expect(view.bubble).toBe("look");
  });

  test("a frameless video's tile reads its poster and length from the file, at the size it had", async () => {
    const mov = PATH.replace(".mp4", "-read.mov");
    setChipHost(async (method, params) => {
      calls.push({ method, params });
      return method === "video.info" && params.src === mov
        ? { durationMs: 42_000, width: 1920, height: 1080, poster: "data:image/jpeg;base64,cmVhZA==", frames: [] }
        : null;
    });
    try {
      await render({
        id: "user-4r",
        version: 1,
        at: 0,
        kind: "user",
        text: "look",
        inlineParts: [
          { kind: "text", text: "look" },
          { kind: "file", name: "screen-demo-read.mov", uri: `file://${encodeURI(mov)}` },
        ],
      } as AcpmuxRow);
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
      const view = shown();
      expect(calls.filter((call) => call.method === "video.info" && call.params.src === mov)).toEqual([
        { method: "video.info", params: { src: mov } },
      ]);
      expect(view.poster).toBe("data:image/jpeg;base64,cmVhZA==");
      expect(view.length).toBe("0:42");
      expect(view.tile?.style.width).toBe("120px");
    } finally {
      setChipHost(async (method, params) => {
        calls.push({ method, params });
        return null;
      });
    }
  });

  // withoutFrames (composer/videoPrompt.ts) sends a video to an agent that takes no images, or past
  // the prompt's budget, as its link alone: the pane's own row keeps that chip, frames emptied, and
  // it is still the tile, with the chip's poster and length.
  test("the pane's own row with a video sent without frames is its tile, with the chip's poster", async () => {
    const chip = {
      ...linkAttachment(PATH, false),
      mimeType: "video/mp4",
      size: 9,
      video: { durationMs: 16_000, width: 1920, height: 1080, poster: "data:image/jpeg;base64,cG9z", frames: [] },
    };
    // The row's text as the pane writes it at send (direct.ts): the prompt and the video's link note.
    await render({
      id: "user-4b",
      version: 1,
      at: 0,
      kind: "user",
      text: promptText("look", [chip]),
      retryAttachments: [chip],
    } as AcpmuxRow);
    const view = shown();
    expect(view.tile).not.toBeNull();
    expect(view.poster).toBe("data:image/jpeg;base64,cG9z");
    expect(view.length).toBe("0:16");
    expect(view.files.join("")).not.toContain("screen-demo.mp4");
    // A chip the host never read is the square tile with no length.
    const { video: _unread, ...bare } = chip;
    await render({
      id: "user-4c",
      version: 1,
      at: 0,
      kind: "user",
      text: promptText("look", [bare]),
      retryAttachments: [bare],
    } as AcpmuxRow);
    expect(shown().tile).not.toBeNull();
    expect(shown().length).toBeUndefined();
    expect(shown().files.join("")).not.toContain("screen-demo.mp4");
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
  // Leo, 2026-11-04: "i can neither preview a vid in place nor have it pop up anymore :(". In a
  // chat on another machine the host granted no stream and Quick Look refused too, and the click
  // did nothing at all. When nothing can play it, the tile says so.
  test("a video nothing can play says so on the tile instead of a click that does nothing", async () => {
    const path = "/home/dev/project/remote-demo.mp4";
    await grantedVideo("user-9", path, "unused");
    const refusal = { ok: false, error: { code: "media_refused", message: "refused" } };
    setChipHost(async (method, params) => {
      calls.push({ method, params });
      return method === "media.load" || method === "video.quickLook" ? refusal : null;
    });
    calls.length = 0;
    const tile = host.querySelector<HTMLElement>(".cv-user__video")!;
    expect(tile.querySelector(".cv-user__video-unplayable")).toBeNull();
    await act(async () => tile.click());
    await settle();
    expect(calls.map((call) => call.method)).toEqual(["media.load", "video.quickLook"]);
    const note = host.querySelector(".cv-user__video .cv-user__video-unplayable");
    expect(note?.textContent).toBe("Can't play this video here");
    // The tile stays, and a later click asks again.
    calls.length = 0;
    await act(async () => host.querySelector<HTMLElement>(".cv-user__video")!.click());
    await settle();
    expect(calls.map((call) => call.method)).toEqual(["media.load", "video.quickLook"]);
  });
} finally {
  afterAll(async () => {
    setChipHost(undefined);
    act(() => root.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });
}
