// https://github.com/manaflow-ai/cmux/issues/59858: a pasted screenshot sent as its file's link drew
// in the sent bubble as a tall, narrow, blurry box, and the bubble showed the composer's note for the
// agent ("Attached file: image.png (image/png, 255275 bytes). Read the linked file with your tools.").
// The thumbnail keeps the image's own shape whatever its `height` attribute says, its picture is
// drawn at the display's density, and the note never reaches the bubble.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { SENT_IMAGE } from "../transcriptSelectors";
import { promptText, withoutAttachedFileNotes, type ComposerAttachment } from "../attachments";
import { setChipHost } from "../chips/host";
import { WHOLE_THUMB_DENSITY, wholeThumbScale } from "../composer/imageWork";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { sentImageSize } from "./userBubbleModel";
import { settleReact } from "../../../../test/support/domTeardown";

/// A 4 x 7 picture: tall, as the report's screenshot, so the shape checks are not of a square.
const PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAHCAIAAACgB3uHAAAAD0lEQVR4nGNoQAIMVOUAAHfEKgFpN9kLAAAAAElFTkSuQmCC";
const PATH = "/Users/someone/Library/Caches/cmux/pasted/image.png";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
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
  setChipHost(undefined);
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const link: ComposerAttachment = {
  id: "paste-1",
  kind: "link",
  name: "image.png",
  mimeType: "image/png",
  size: 255275,
  path: PATH,
};
const typed =
  "In this modal when we are adding Claude accounts, we should also have the option to add Claude setup tokens as well.";

test("the bubble shows what the person typed, never the note for the agent", async () => {
  const sent = promptText(typed, [link]);
  expect(sent).toBe(
    `${typed}\n\nAttached file: image.png (image/png, 255275 bytes). Read the linked file with your tools.`,
  );
  expect(withoutAttachedFileNotes(sent)).toBe(typed);

  setChipHost(async () => undefined);
  const container = installDom();
  // acpmux's echo: the text with the note, then the file's link.
  const row: AcpmuxRow = {
    id: "u-1",
    version: 1,
    kind: "user",
    at: Date.now(),
    text: sent,
    inlineParts: [
      { kind: "text", text: sent },
      { kind: "file", name: "image.png", mimeType: "image/png", uri: `file://${PATH}` },
    ],
  } as AcpmuxRow;
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <UserBubble row={row} text={sent} />
      </TurnActionsContext.Provider>,
    );
  });
  const text = container.textContent ?? "";
  expect(text).toContain("setup tokens");
  expect(text).not.toContain("Attached file");
  expect(text).not.toContain("Read the linked file");
});

test("a sent image keeps its own shape: its style sets a width, an aspect ratio and height auto", async () => {
  setChipHost(async (method) => (method === "image.load" ? { src: PNG } : undefined));
  const container = installDom();
  const row: AcpmuxRow = {
    id: "local-1",
    version: 1,
    kind: "user",
    at: Date.now(),
    text: typed,
    retryAttachments: [link],
  };
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ImageViewerContext.Provider value={() => undefined}>
        <TurnActionsContext.Provider value={{}}>
          <UserBubble row={row} text={typed} />
        </TurnActionsContext.Provider>
      </ImageViewerContext.Provider>,
    );
  });
  for (let turn = 0; turn < 50 && !container.querySelector(SENT_IMAGE); turn++)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const image = container.querySelector<HTMLImageElement>(SENT_IMAGE);
  expect(image).not.toBeNull();
  // The `height` attribute is the image's natural height; the style's `auto` must win over it, so a
  // CSS rule that misses this band can never draw it at that height beside a thumbnail's width.
  expect(image!.style.height).toBe("auto");
  const { width, height } = sentImageSize({
    width: Number(image!.getAttribute("width")),
    height: Number(image!.getAttribute("height")),
  });
  expect(image!.style.width).toBe(`${width}px`);
  expect(image!.style.aspectRatio.replace(/\s/g, "")).toBe(`${width}/${height}`);
  expect([image!.getAttribute("width"), image!.getAttribute("height")]).toEqual(["4", "7"]);
});

test("a sent image's box keeps the issue's screenshot's shape", () => {
  // The pasted modal in the report: 1352 x 2358.
  const box = sentImageSize({ width: 1352, height: 2358 });
  expect(box.height).toBe(160);
  expect(Math.abs(box.width / box.height - 1352 / 2358)).toBeLessThan(0.01);
});

test("a linked image's preview is drawn at the display's density, not 1x", () => {
  for (const [width, height] of [
    [1352, 2358],
    [2880, 900],
    [1200, 800],
  ] as const) {
    const box = sentImageSize({ width, height });
    const scale = wholeThumbScale(width, height);
    // Its pixels cover the box at WHOLE_THUMB_DENSITY, or are all the image has.
    expect(Math.round(height * scale)).toBeGreaterThanOrEqual(Math.min(height, WHOLE_THUMB_DENSITY * box.height));
    expect(Math.round(width * scale)).toBeGreaterThanOrEqual(Math.min(width, WHOLE_THUMB_DENSITY * box.width) - 1);
  }
  // Never upscaled past the image's own pixels.
  expect(wholeThumbScale(100, 50)).toBe(1);
});
