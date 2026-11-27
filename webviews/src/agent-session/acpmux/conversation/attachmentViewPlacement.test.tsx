// One rule for where a sent prompt's attachments draw, in both views (Leo, 2026-11-27: inline mode was
// showing "inline + top bar", and "pure inline isn't giving pure inline"):
// - inline: each attachment once, in the bubble at its place in the text; never in a band above it.
//   An attachment with no recorded place (an old prompt, one sent from a strip-view composer, a
//   strip chip beside placed ones) goes at the end of the bubble, after its text.
// - strip (at top): each attachment once, in the band above the bubble; never in the bubble.
// A prompt of attachments alone has no text to place them in: it draws them alone, the same in
// both views. Each shape below is one acpmux records (the first is Leo's own prompt, as recorded).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, PromptContentPart } from "../model";
import { type AttachmentView, setComposerSettings } from "../composerSettings";
import { PresentationContext } from "./presentationContextModel";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { bubbleLayout } from "./bubbleParts";
import { recordedPromptParts } from "../inlinePrompt";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "localStorage"])
    saved.set(key, scope[key]);
  saved.set("IS_REACT_ACT_ENVIRONMENT", scope.IS_REACT_ACT_ENVIRONMENT);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

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
  setComposerSettings({ attachmentView: "strip" });
});

async function render(row: AcpmuxRow, view: AttachmentView): Promise<HTMLElement> {
  setComposerSettings({ attachmentView: view });
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <PresentationContext.Provider value="messages">
        <TurnActionsContext.Provider value={{}}>
          <UserBubble row={row} text={row.text ?? ""} />
        </TurnActionsContext.Provider>
      </PresentationContext.Provider>,
    );
  });
  return container;
}

const MEDIA = ".cv-user__image, .cv-user__image-placeholder, .cv-user__image-failed, .acpmux-file-chip";
/// Each attachment's draws: above the bubble (`top`) and in it (`inline`).
function draws(container: HTMLElement) {
  const all = [...container.querySelectorAll(MEDIA)];
  const inline = all.filter((node) => node.closest(".cv-user__body")).length;
  return { top: all.length - inline, inline };
}

const src = "data:image/png;base64,iVBORw0KGgo=";
const id = "1c9f3c9c6e136553f96de14da27b07a13f67204b4f1b5ac8ca8d2a81fa70712e";
const image = { id, mimeType: "image/png", name: "image.png", width: 142, height: 120 };
const uri = "file:///Users/me/Library/Application%20Support/cmux-next/Chat%20Uploads/s/p/0/image.png";
const row = (fields: Partial<AcpmuxRow>): AcpmuxRow => ({
  id: "user-1",
  version: 1,
  kind: "user",
  at: Date.now() - 10_000,
  ...fields,
});
/// The row the transcript builds from acpmux's record (`recordedPromptParts`).
const recorded = (text: string, parts: unknown[], images = [image]): AcpmuxRow =>
  row({ text, images, inlineParts: recordedPromptParts({ inlineParts: parts }) });

const before = "the inline attachments are bugging out right now like ";
const after = "the inline gives inline + top bar, and pure inline isn't giving pure inline";
const placedImage = { blockIndex: 1, kind: "image", ...image, placed: true, size: 5970 };
const companion = { companionOf: 1, kind: "file", name: "image.png", placed: true, uri };

type Shape = { name: string; row: AcpmuxRow; attachments: number; alone?: boolean };
const shapes: Shape[] = [
  {
    // Leo's prompt exactly as acpmux recorded it (2026-11-27): text, a placed image, its original, text.
    name: "Leo's placed image mid-text",
    row: recorded(`${before}\n${after}`, [{ kind: "text", text: before }, placedImage, companion, { kind: "text", text: after }]),
    attachments: 1,
  },
  {
    name: "a placed image first, then text",
    row: recorded(after, [{ ...placedImage, blockIndex: 0 }, { ...companion, companionOf: 0 }, { kind: "text", text: after }]),
    attachments: 1,
  },
  {
    // A replay that kept the original's link but not its `companionOf`, with the retained original.
    name: "a placed image whose original lost its companionOf",
    row: {
      ...recorded(`${before}\n${after}`, [
        { kind: "text", text: before },
        placedImage,
        { kind: "file", name: "image.png", placed: true, uri },
        { kind: "text", text: after },
      ]),
      retryAttachments: [
        { id: "a", kind: "image", name: "image.png", mimeType: "image/png", size: 5970, originalPath: decodeURIComponent(uri.slice(7)) },
      ],
    } as AcpmuxRow,
    attachments: 1,
  },
  {
    // acpmux from before the `placed` mark: text after the attachment still records its place.
    name: "an image mid-text with no placed mark",
    row: recorded(`${before}\n${after}`, [
      { kind: "text", text: before },
      { ...placedImage, placed: undefined },
      { ...companion, placed: undefined },
      { kind: "text", text: after },
    ]),
    attachments: 1,
  },
  {
    // A strip-view composer (New Tab's) sends its chips unplaced, after the text.
    name: "a prompt sent from a strip-view composer",
    row: recorded(after, [{ kind: "text", text: after }, { ...placedImage, placed: undefined }, { ...companion, placed: undefined }]),
    attachments: 1,
  },
  {
    name: "a placed image beside a chip the composer left in its strip",
    row: recorded(`${before}\n${after}`, [
      { kind: "text", text: before },
      placedImage,
      companion,
      { kind: "text", text: after },
      { kind: "image", id: "second", mimeType: "image/png", name: "two.png", width: 40, height: 30, blockIndex: 4 },
    ], [image, { id: "second", mimeType: "image/png", name: "two.png", width: 40, height: 30 }]),
    attachments: 2,
  },
  {
    name: "an old prompt: its text and images, no recorded parts",
    row: row({ text: after, images: [{ ...image, src }] }),
    attachments: 1,
  },
  {
    name: "an image alone",
    row: recorded("", [placedImage, companion]),
    attachments: 1,
    alone: true,
  },
];

for (const shape of shapes) {
  test(`inline view: ${shape.name} draws each attachment once, in the bubble`, async () => {
    const container = await render(shape.row, "inline");
    const drawn = draws(container);
    if (shape.alone) expect(drawn.top + drawn.inline).toBe(shape.attachments);
    else expect(drawn).toEqual({ top: 0, inline: shape.attachments });
    expect(container.querySelector(".cv-user__body")?.textContent).toContain(shape.row.text?.trim().slice(0, 20) ?? "");
  });
  test(`strip view: ${shape.name} draws each attachment once, above the bubble`, async () => {
    const container = await render(shape.row, "strip");
    const drawn = draws(container);
    if (shape.alone) expect(drawn.top + drawn.inline).toBe(shape.attachments);
    else expect(drawn).toEqual({ top: shape.attachments, inline: 0 });
  });
  // Find and the row's estimate read bubbleLayout: it must lay the prompt out as the bubble draws it.
  test(`bubbleLayout: ${shape.name} agrees with the bubble in both views`, () => {
    if (shape.alone) return;
    const media = (parts: readonly PromptContentPart[] | undefined) =>
      (parts ?? []).filter((part) => part.kind !== "text").length;
    const inline = bubbleLayout(shape.row, "inline");
    const strip = bubbleLayout(shape.row, "strip");
    expect({ band: inline?.band.length ?? 0, parts: media(inline?.parts) }).toEqual({ band: 0, parts: shape.attachments });
    expect({ band: strip?.band.length ?? 0, parts: media(strip?.parts) }).toEqual({ band: shape.attachments, parts: 0 });
  });
}
