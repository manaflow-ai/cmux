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
    images: [...host.querySelectorAll("img")].filter((img) => !tile?.contains(img)).map((img) => img.getAttribute("src")),
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
    await act(async () => view.tile!.click());
    expect(calls.at(-1)).toEqual({ method: "video.quickLook", params: { src: PATH } });
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
