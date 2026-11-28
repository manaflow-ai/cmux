// An image file dropped on the composer (New Tab's too) goes as its file's link and draws in the
// prompt's file band (UserBubble.tsx `SentLinkedImage` in `cv-user__files`). The thumbnail rules
// matched only the image bands (`.cv-user__images`, `.cv-user__inline-image`), so in the file band
// the <img>'s `height` attribute drew it at its full height, stretched to the thumbnail's width,
// inside a native button's grey frame. The thumbnail and its button carry their own classes, and
// the rules match those.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { SENT_IMAGE } from "../transcriptSelectors";
import { promptText, withoutAttachedFileNotes, type ComposerAttachment } from "../attachments";
import { setChipHost } from "../chips/host";
import { ImageViewerContext } from "./imageViewerContext";
import { TurnActionsContext } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { settleReact } from "../../../../test/support/domTeardown";

const PNG =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
const PATH = "/Users/someone/Desktop/Screenshot 2026-11-26 at 7.10.00 PM.png";

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

/// The pane's own row for a prompt sent with a dropped image file, before acpmux's echo.
const droppedImageRow = (): AcpmuxRow => ({
  id: "local-1",
  version: 1,
  kind: "user",
  at: Date.now(),
  text: "why does this overlap",
  retryAttachments: [
    { id: "drop-1", kind: "link", name: "Screenshot.png", mimeType: "image/png", size: 0, path: PATH },
  ],
});

/// The rule whose selector list names `selector`, from a stylesheet's text: its declarations.
function ruleFor(css: string, selector: string): string | undefined {
  for (const match of css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = match[1]!.split(",").map((part) => part.trim());
    if (selectors.includes(selector)) return match[2];
  }
  return undefined;
}

test("a dropped image file's thumbnail in the file band carries its own classes", async () => {
  setChipHost(async (method) => (method === "image.load" ? { src: PNG } : undefined));
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ImageViewerContext.Provider value={() => undefined}>
        <TurnActionsContext.Provider value={{}}>
          <UserBubble row={droppedImageRow()} text="why does this overlap" />
        </TurnActionsContext.Provider>
      </ImageViewerContext.Provider>,
    );
  });
  // The host's read answers in a later task.
  for (let turn = 0; turn < 50 && !container.querySelector(SENT_IMAGE); turn++)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const image = container.querySelector<HTMLImageElement>(`.cv-user__files ${SENT_IMAGE}`);
  expect(image?.getAttribute("src")).toBe(PNG);
  expect(image?.closest("button")?.classList.contains("cv-user__image-open")).toBe(true);
});

test("the thumbnail rules match the thumbnail and its button in any band", () => {
  const css = readFileSync(new URL("./conversation.css", import.meta.url), "utf8");
  const thumbnail = ruleFor(css, SENT_IMAGE);
  expect(thumbnail).toMatch(/height:\s*auto/);
  expect(thumbnail).toMatch(/max-width:\s*100%/);
  expect(thumbnail).toMatch(/object-fit:\s*contain/);
  const button = ruleFor(css, ".cv-user__image-open");
  expect(button).toMatch(/padding:\s*0/);
  expect(button).toMatch(/border:\s*0/);
  expect(button).toMatch(/background:\s*none/);
});

// The composer tells the agent about a linked file in the prompt's text (attachments.ts
// `promptText`); the bubble showed that note as if the person had typed it.
test("a linked file's note for the agent stays out of the bubble", async () => {
  const link: ComposerAttachment = {
    id: "drop-1",
    kind: "link",
    name: "Screenshot 2026-11-26 at 7.27.20 PM.png",
    mimeType: "image/png",
    size: 492191,
    path: PATH,
  };
  const typed = "text is overlaying text on top of each other (see the screenshot)";
  const sent = promptText(typed, [link]);
  expect(sent).toContain("Attached file: Screenshot 2026-11-26 at 7.27.20 PM.png (image/png, 492191 bytes).");
  expect(withoutAttachedFileNotes(sent)).toBe(typed);
  // A line the person wrote that only starts the same way stays.
  expect(withoutAttachedFileNotes("Attached file: see above")).toBe("Attached file: see above");

  setChipHost(async () => undefined);
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <UserBubble row={{ ...droppedImageRow(), text: sent, retryAttachments: [link] }} text={sent} />
      </TurnActionsContext.Provider>,
    );
  });
  const bubble = container.querySelector(".cv-user__bubble")?.textContent ?? "";
  expect(bubble).toContain(typed);
  expect(bubble).not.toContain("Attached file");
});
