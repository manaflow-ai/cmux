// Leo, 2026-11-22, on a sent message whose pasted image drew as "image.png 0 byte" and whose
// screen recording drew as its tile and again as a "179.9 MB" file chip: "WHAT THE FUCK IS THIS
// SITUATION MAN WITH THESE ATTACHMENTS!?". The rows here are his prompt as acpmux recorded it
// (session 01a18a35, seq 5359294), trimmed to its attachments.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow, PromptContentPart } from "../model";
import { inlineToken, linkAttachment, type ComposerAttachment } from "../attachments";
import { fitPromptBudget } from "../promptBudget";
import { inlinePrompt, normalizePromptContentPart, recordedPromptParts } from "../inlinePrompt";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { bubbleLayout } from "./bubbleParts";
import { linkedImagePath } from "./userBubbleModel";
import { settleReact } from "../../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "localStorage",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
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
});

async function render(row: AcpmuxRow): Promise<HTMLElement> {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <UserBubble row={row} text={row.text ?? ""} />
      </TurnActionsContext.Provider>,
    );
  });
  // The linked image's read (no host here) settles to its chip.
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return container;
}

const UPLOADS = "file:///Users/leoli/.acpmux/uploads/01a18a35-b1e8-7951-ba2f-703bf916b9a6";
const VIDEO = "Screen Recording 2026-11-22 at 2.11.52 AM.mov";
const videoUri = (upload: string) => `${UPLOADS}/${upload}/${encodeURIComponent(VIDEO)}`;
const VIDEO_SIZE = 188_649_435;
const IMAGE_URI = `${UPLOADS}/01a202bf-bff1-773e-a292-70c86e8c0d52/image.png`;

// His prompt's parts as acpmux's history keeps them: the image that went as its original's link
// with a recorded size of 0, then the same recording attached twice (two uploads of it).
const recorded = [
  { kind: "file", name: "image.png", placed: true, size: 0, uri: IMAGE_URI },
  { kind: "text", text: "ok i guess we still haven't fixed this" },
  {
    kind: "file",
    mimeType: "video/quicktime",
    name: VIDEO,
    placed: true,
    size: VIDEO_SIZE,
    uri: videoUri("01a202c0-543b-7499-b2b5-ecd1d33b5c68"),
  },
  { kind: "text", text: `Frames from the video ${VIDEO} (2:08, 4096×2154), in order, at: 0:00.0.` },
  { kind: "text", text: `${VIDEO} frame at 0:00.0` },
  { kind: "image", id: "frame-0", mimeType: "image/jpeg", name: `${VIDEO} frame at 0:00.0` },
  { kind: "text", text: "FUCKING" },
  {
    kind: "file",
    mimeType: "video/quicktime",
    name: VIDEO,
    placed: true,
    size: VIDEO_SIZE,
    uri: videoUri("01a202c3-40d0-73b8-b17a-3dacf6bc421b"),
  },
  { kind: "text", text: "NEW LINE SITUATION" },
];

/// The row a reload draws: acpmux's history read back as the pane reads every user_message.
function replayedRow(): AcpmuxRow {
  return {
    id: "user-1",
    version: 1,
    kind: "user",
    at: Date.now() - 10_000,
    text: "ok i guess we still haven't fixed this",
    images: [{ id: "frame-0", mimeType: "image/jpeg", name: `${VIDEO} frame at 0:00.0` }],
    inlineParts: recordedPromptParts({ inlineParts: recorded }),
  };
}

const videoTiles = (container: HTMLElement) => container.querySelectorAll(".cv-user__video").length;
const fileChips = (container: HTMLElement) => [...container.querySelectorAll(".acpmux-file-chip")];
const chipText = (container: HTMLElement) => fileChips(container).map((chip) => chip.textContent ?? "");

test("(a) a link chip's unknown size is never sent as 0 bytes", () => {
  // An image past the prompt's budget goes as the link to its saved original (promptBudget.ts).
  const preview: ComposerAttachment = {
    id: "shot",
    kind: "image",
    name: "image.png",
    mimeType: "image/png",
    size: 93_779,
    data: "A".repeat(4096),
    originalPath: "/Users/leoli/.acpmux/uploads/s/u/image.png",
  };
  const input = `${inlineToken("shot")} look`;
  const [linked] = fitPromptBudget(input, [preview], {}, 64);
  expect(linked!.kind).toBe("link");
  // A dropped file's link chip has no size either.
  const dropped = linkAttachment("/tmp/notes.bin", false);
  for (const chip of [linked!, dropped]) {
    const built = inlinePrompt(`${inlineToken(chip.id)} look`, [chip])!;
    const part = built.parts.find((one) => one.kind === "file")!;
    expect(part.kind === "file" && "size" in part).toBe(false);
    expect(built.display.find((one) => one.kind === "file")?.size).toBeUndefined();
  }
  // A known size, even 0 of a typed file, is kept.
  const empty: ComposerAttachment = { ...dropped, id: "empty", mimeType: "text/plain" };
  const typed = inlinePrompt(`${inlineToken("empty")} look`, [empty])!;
  expect(typed.display[0]?.size).toBe(0);
});

test("(a) a recorded 0 with no type reads back as no size", () => {
  const part = normalizePromptContentPart({ kind: "file", name: "image.png", size: 0, uri: IMAGE_URI });
  expect(part?.kind === "file" && part.size).toBeUndefined();
  expect(normalizePromptContentPart({ kind: "file", name: "a.txt", mimeType: "text/plain", size: 0 })).toMatchObject({
    size: 0,
  });
});

test("(a) an image sent as its file's link draws as an image, never as a 0-byte chip", async () => {
  expect(linkedImagePath(replayedRow().inlineParts![0]!)).toBe(
    "/Users/leoli/.acpmux/uploads/01a18a35-b1e8-7951-ba2f-703bf916b9a6/01a202bf-bff1-773e-a292-70c86e8c0d52/image.png",
  );
  const container = await render(replayedRow());
  // No host reads the file here, so it falls back to its chip: named, never "0 byte".
  expect(chipText(container).some((text) => /\b0\s*byte/i.test(text))).toBe(false);
  expect(chipText(container).some((text) => text.includes("image.png"))).toBe(true);
});

test("(b) one video, attached twice, is one tile and no file chip after a reload", async () => {
  const row = replayedRow();
  const container = await render(row);
  expect(videoTiles(container)).toBe(1);
  expect(chipText(container).some((text) => text.includes("MB") || text.includes(".mov"))).toBe(false);
  // The row's estimate measures the same band.
  const band = bubbleLayout(row)!.band;
  expect(band.filter((part) => part.kind === "file" && part.mimeType === "video/quicktime")).toHaveLength(1);
});

test("(b) one video is one tile in the pane's own row before acpmux's echo", async () => {
  const chip = (id: string, upload: string): ComposerAttachment => ({
    id,
    kind: "link",
    name: VIDEO,
    mimeType: "video/quicktime",
    size: VIDEO_SIZE,
    path: decodeURIComponent(new URL(videoUri(upload)).pathname),
  });
  const chips = [chip("v1", "01a202c0"), chip("v2", "01a202c3")];
  const built = inlinePrompt(`${inlineToken("v1")} ok ${inlineToken("v2")} more`, chips)!;
  const row: AcpmuxRow = {
    id: "local-1",
    version: 1,
    kind: "user",
    at: Date.now(),
    text: "ok more",
    inlineParts: built.parts as PromptContentPart[],
    retryAttachments: chips,
  };
  const container = await render(row);
  expect(videoTiles(container)).toBe(1);
  expect(fileChips(container)).toHaveLength(0);
});

test("(b) one video attached once is one tile", async () => {
  const once = recorded.filter((_, index) => index !== 7);
  const row = { ...replayedRow(), inlineParts: recordedPromptParts({ inlineParts: once }) };
  const container = await render(row);
  expect(videoTiles(container)).toBe(1);
  expect(chipText(container).some((text) => text.includes(".mov"))).toBe(false);
});
