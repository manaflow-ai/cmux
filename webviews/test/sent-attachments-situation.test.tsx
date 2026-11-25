// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo, 2026-11-22 (ask-249ca4423f), over a sent prompt, paraphrased: "what is this situation with
// these attachments!?" acpmux's record of that prompt (the coordinator chat's record),
// cut down: a pasted image sent as the link to its original (promptBudget.ts `originalLink`: size 0,
// no type) drew as "image.png 0 byte", and the same screen recording attached twice (two uploads, one
// name) drew a video tile and then a "Screen Recording ... .mov 179.9 MB" file chip. The two spinner
// tiles in the screenshot are not a bug: the pasted image itself is a crop of a spinner tile.
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
const { sentVideoOf, sentVideosOf } = await import("../src/agent-session/acpmux/conversation/sentVideos");
const { shownFileSize } = await import("../src/agent-session/acpmux/fileAttachmentModel");

const UPLOADS = "/Users/leoli/.acpmux/uploads/01a18a35-b1e8-7951-ba2f-703bf916b9a6";
const uri = (path: string) => `file://${path.split("/").map(encodeURIComponent).join("/")}`;
const NAME = "Screen Recording 2026-11-22 at 2.11.52 AM.mov";
const FIRST = `${UPLOADS}/01a202c0-543b-7499-b2b5-ecd1d33b5c68/${NAME}`;
const SECOND = `${UPLOADS}/01a202c3-40d0-73b8-b17a-3dacf6bc421b/${NAME}`;
const NOTE = `Frames from the video ${NAME} (2:08, 4096×2154), in order, at: 0:00.0, 0:08.0.`;
const frames = ["0:00.0", "0:08.0"].map((at, index) => ({
  id: String(index + 1).repeat(64),
  mimeType: "image/jpeg",
  name: `${NAME} frame at ${at}`,
  width: 1280,
  height: 673,
}));
const PASTED = { id: "f".repeat(64), mimeType: "image/png", name: "image.png", width: 140, height: 138 };

const row = {
  id: "user-leo",
  version: 1,
  at: 0,
  kind: "user",
  text: `ok i guess we still haven't fixed this\n${NOTE}\n${frames.map((frame) => frame.name).join("\n")}`,
  images: [...frames, PASTED],
  inlineParts: [
    { kind: "file", name: "image.png", placed: true, size: 0, uri: uri(`${UPLOADS}/01a202bf/image.png`) },
    { kind: "text", text: "ok i guess we still haven't fixed this" },
    { kind: "file", mimeType: "video/quicktime", name: NAME, placed: true, size: 188649435, uri: uri(FIRST) },
    { kind: "text", text: NOTE },
    ...frames.flatMap((frame) => [
      { kind: "text", text: frame.name },
      { kind: "image", ...frame },
    ]),
    { kind: "text", text: "the attachments still have some sort of move/upload thing" },
    { kind: "image", ...PASTED, placed: true, size: 12628 },
    { kind: "file", name: "image.png", placed: true, companionOf: 9, uri: uri(`${UPLOADS}/01a202c1/image.png`) },
    { kind: "text", text: "and" },
    { kind: "file", mimeType: "video/quicktime", name: NAME, placed: true, size: 188649435, uri: uri(SECOND) },
    { kind: "text", text: "new line situation in the composer" },
  ],
} as unknown as AcpmuxRow;

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
setChipHost(async () => null);
const actions = { promptImage: async (id: string) => `data:image/jpeg;base64,${id.slice(0, 4)}` };

async function render(shown: AcpmuxRow) {
  await act(async () => {
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble row={shown} text={shown.text ?? ""} />
      </TurnActionsContext.Provider>,
    );
  });
  await act(async () => {
    await Promise.resolve();
  });
}

try {
  test("a link that names no size draws no size; a file of known type keeps its own", () => {
    expect(shownFileSize({ size: 0 })).toBeUndefined();
    expect(shownFileSize({ size: 0, mimeType: "" })).toBeUndefined();
    expect(shownFileSize({})).toBeUndefined();
    expect(shownFileSize({ size: 0, mimeType: "text/plain" })).toBe(0);
    expect(shownFileSize({ size: 93779 })).toBe(93779);
  });

  test("one recording attached twice is two video tiles, each at its own upload, both with the note's length", () => {
    const videos = sentVideosOf(row);
    expect(videos.map((video) => [video.path, video.length])).toEqual([
      [FIRST, "2:08"],
      [SECOND, "2:08"],
    ]);
    const parts = row.inlineParts!.filter((part) => part.kind === "file" && part.mimeType === "video/quicktime");
    expect(parts.map((part) => sentVideoOf(part as never, videos)?.path)).toEqual([FIRST, SECOND]);
  });

  test("Leo's sent prompt: no 0 byte chip, no file chip for the recording, one tile for the recording", async () => {
    await render(row);
    const text = host.textContent ?? "";
    expect(text).not.toContain("0 byte");
    // The same recording sent twice draws once (#51971, withoutRepeatedVideos), never as a file chip.
    expect(host.querySelectorAll(".cv-user__video")).toHaveLength(1);
    const chips = [...host.querySelectorAll(".acpmux-file-chip")].map((chip) => chip.textContent ?? "");
    expect(chips.some((chip) => chip.includes(".mov"))).toBe(false);
    // The pasted image's link is still its file chip, by its name alone.
    expect(chips.filter((chip) => chip.includes("image.png"))).toHaveLength(1);
  });
} finally {
  afterAll(async () => {
    setChipHost(undefined);
    act(() => root.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });
}
