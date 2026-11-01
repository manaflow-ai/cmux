// Leo, 2026-11-01: "i wanna be able to select all in composer which also selects all the attachments
// as the copy as well". Select All in the composer covers the attachments with the text: the ones
// placed in the text wear the selection, Copy puts the text and each attachment on the pasteboard
// (the host's `composer.copy`), a paste of that copy into another composer brings both back in the
// same order, and Cut takes both out (composer/composerCopy.ts, composer/inlineNode.ts).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type ComponentProps } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { inlineToken, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { composerCopy, forgetCopy, pastePlan, rememberCopy } from "../src/agent-session/acpmux/composer/composerCopy";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "createImageBitmap",
  "OffscreenCanvas",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    ...imageEngine(),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

// A PNG's signature and header, padded past a spacer image's size: a copied screenshot.
const PNG = Uint8Array.from([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  // Its size, 640x480 (the composer reads it before it decodes the picture), then filler.
  0,
  0,
  2,
  0x80,
  0,
  0,
  1,
  0xe0,
  ...Array(504).fill(7),
]);
/// The engine's image decoder and canvas, which jsdom lacks. Every attached image is decoded and
/// re-encoded to strip its metadata (composer/imageWork.ts prepareImage, since #24652); with no
/// engine to draw it is no image. This one reads the file's bytes as a real decode does, and each
/// canvas encodes back to the screenshot's own PNG.
function imageEngine() {
  return {
    createImageBitmap: async (source: Blob) => {
      await source.arrayBuffer();
      return { width: 640, height: 480, close() {} };
    },
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([PNG], { type });
      }
    },
  };
}

const pngBase64 = btoa(String.fromCharCode(...PNG));
/// Yields to React until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

let composerCount = 0;
type ComposerProps = ComponentProps<typeof import("../src/agent-session/acpmux/Composer").Composer>;

/// `extra`: more props; `newChat`, a chat not started yet (no session id), whose text goes to
/// `onUnsentDraft`.
async function openComposer(
  sent: { text: string; attachments: ComposerAttachment[] }[] = [],
  extra: Partial<ComposerProps> = {},
  newChat = false,
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const sessionId = newChat ? undefined : `chat-${++composerCount}`;
  const snapshot = noChat(
    [],
    sessionId ? { sessionId, summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 } } : {},
  );
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        {...(sessionId ? { sessionId } : {})}
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
        {...extra}
      />,
    ),
  );
  return handle;
}

const field = () => host.querySelector<HTMLElement>('[role="combobox"]')!;
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;

const screenshot = (name = "image.png") => new File([PNG], name, { type: "image/png" });

const IMAGE: ComposerAttachment = {
  id: "shot",
  kind: "image",
  name: "Screenshot.png",
  mimeType: "image/png",
  size: PNG.length,
  data: pngBase64,
};
const LINK: ComposerAttachment = {
  id: "link:/Users/you/notes.md",
  kind: "link",
  name: "notes.md",
  mimeType: "text/markdown",
  size: 12,
  path: "/Users/you/notes.md",
};
const MARK = "\uFFFC";

/// What the page posted to the host (`window.webkit.messageHandlers.agentSession`).
let posted: { method: string; params: Record<string, unknown> }[] = [];
function recordHost() {
  posted = [];
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method: string; params: Record<string, unknown> }) => {
          // The composer's other host calls (a project's icon) are not the copy's.
          if (message.method === "composer.copy") posted.push({ method: message.method, params: message.params });
          // As AgentPaneComposerCopy.swift answers: each item kept, under its plain name.
          const items = (message.params.items as { name: string }[] | undefined) ?? [];
          return { ok: true, value: { files: items.map((item, index) => ({ item: index, name: item.name })) } };
        },
      },
    },
  };
}

/// A copy or cut on the prompt as WebKit delivers it; what the page wrote to the event's clipboard.
async function clip(type: "copy" | "cut") {
  const written = new Map<string, string>();
  const event = new dom.window.Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", {
    value: { setData: (kind: string, value: string) => void written.set(kind, value), getData: () => "" },
  });
  await act(async () => {
    host.querySelector(".ProseMirror")!.dispatchEvent(event);
  });
  return { event, written };
}

/// A paste of what the host wrote for a copy: its text, then each attachment as a file.
async function pasteBack(plain: string, files: File[]) {
  const data = {
    files,
    types: [...(files.length ? ["Files"] : []), ...(plain ? ["text/plain"] : [])],
    getData: (type: string) => (type === "text/plain" ? plain : ""),
  };
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  await act(async () => {
    field().dispatchEvent(event);
  });
}

afterEach(() => {
  delete (dom.window as unknown as { webkit?: unknown }).webkit;
  dom.window.localStorage.clear();
});

test("Select All marks every attachment placed in the text as selected", async () => {
  const composer = await openComposer();
  await act(async () =>
    composer.current!.restore(`look ${inlineToken(IMAGE.id)} and ${inlineToken(LINK.id)} here`, [IMAGE, LINK]),
  );
  await until(() => field().querySelectorAll("[data-inline-attachment]").length === 2, "the placed attachments");
  expect(field().querySelectorAll(".acpmux-md-inline-selected")).toHaveLength(0);
  await act(async () => markdownField().selectAll());
  expect(field().querySelectorAll(".acpmux-md-inline-selected")).toHaveLength(2);
});

test("Select All marks the strip's attachments selected too, and Copy carries them first", async () => {
  recordHost();
  const composer = await openComposer();
  // Restored with no token in the text: the attachment shows in the strip alone.
  await act(async () => composer.current!.restore("only text", [IMAGE]));
  await until(
    () => Boolean(host.querySelector(".acpmux-attachments") ?? field().querySelector("[data-inline-attachment]")),
    "the attachment shown",
  );
  // The composer places a strip attachment in the text once it is ready (inlineAttachments.tsx
  // `ready`): read where it is now.
  await act(async () => markdownField().selectAll());
  const strip = host.querySelector(".acpmux-attachments");
  const placed = field().querySelectorAll(".acpmux-md-inline-selected").length;
  expect(placed + (strip?.hasAttribute("data-selected") ? 1 : 0)).toBeGreaterThan(0);
  const { event } = await clip("copy");
  expect(event.defaultPrevented).toBe(true);
  expect(posted.map((post) => post.method)).toEqual(["composer.copy"]);
  expect(posted[0]!.params.items).toEqual([{ name: "Screenshot.png", mimeType: "image/png", data: pngBase64 }]);
});

test("Copy of the whole draft puts its text and each attachment on the pasteboard, in order", async () => {
  recordHost();
  const composer = await openComposer();
  await act(async () =>
    composer.current!.restore(`look ${inlineToken(IMAGE.id)} and ${inlineToken(LINK.id)} here`, [IMAGE, LINK]),
  );
  await until(() => field().querySelectorAll("[data-inline-attachment]").length === 2, "the placed attachments");
  await act(async () => markdownField().selectAll());
  const { event, written } = await clip("copy");
  expect(event.defaultPrevented).toBe(true);
  expect(written.get("text/plain")).toBe("look  and  here");
  expect(posted).toEqual([
    {
      method: "composer.copy",
      params: {
        text: "look  and  here",
        items: [
          { name: "Screenshot.png", mimeType: "image/png", data: pngBase64 },
          { name: "notes.md", mimeType: "text/markdown", path: "/Users/you/notes.md" },
        ],
      },
    },
  ]);
  // Nothing was taken out by a copy.
  expect(composer.current!.wakeState().attachments ?? []).toHaveLength(2);
});

test("a copy of text alone stays the field's own copy", () => {
  expect(composerCopy([{ text: "here more" }], false, [IMAGE])).toBeUndefined();
});

test("Cut of the whole draft takes the text and the attachments out together", async () => {
  recordHost();
  const composer = await openComposer();
  await act(async () =>
    composer.current!.restore(`look ${inlineToken(IMAGE.id)} and ${inlineToken(LINK.id)} here`, [IMAGE, LINK]),
  );
  await until(() => field().querySelectorAll("[data-inline-attachment]").length === 2, "the placed attachments");
  await act(async () => markdownField().selectAll());
  await clip("cut");
  expect(posted.map((post) => post.method)).toEqual(["composer.copy"]);
  await until(() => (composer.current!.wakeState().attachments ?? []).length === 0, "the attachments cut");
  expect(markdownField().value()).toBe("");
});

test("a copy pasted into another composer brings the text and the attachments back in the same order", async () => {
  recordHost();
  const first = await openComposer();
  await act(async () =>
    first.current!.restore(`look ${inlineToken(IMAGE.id)} and ${inlineToken("pic2")} here`, [
      IMAGE,
      { ...IMAGE, id: "pic2", name: "Second.png" },
    ]),
  );
  await until(() => field().querySelectorAll("[data-inline-attachment]").length === 2, "the placed attachments");
  await act(async () => markdownField().selectAll());
  const { written } = await clip("copy");
  // Another chat's composer: none of these attachments is its own.
  act(() => root?.unmount());
  root = undefined;
  const second = await openComposer();
  // WebKit gives a page a pasteboard of file URLs as its files with no text (it keeps the paths
  // private): the text comes back from the copy kept here (review at f90c7e8c).
  void written;
  await pasteBack("", [screenshot("Screenshot.png"), screenshot("Second.png")]);
  await until(() => (second.current!.wakeState().attachments ?? []).length === 2, "the pasted attachments");
  await until(() => field().querySelectorAll("[data-inline-attachment]").length === 2, "both in the text");
  const value = markdownField().value();
  const shape = new RegExp(`^look ${MARK}[^${MARK}]+${MARK} and ${MARK}[^${MARK}]+${MARK} here$`);
  expect(value).toMatch(shape);
  // In their copied order: the first file where the first image was.
  const ids = [...value.matchAll(new RegExp(`${MARK}([^${MARK}]+)${MARK}`, "g"))].map((match) => match[1]);
  const names = ids.map(
    (id) =>
      (second.current!.wakeState().attachments ?? []).find(
        (chip) => encodeURIComponent(chip.id) === id || chip.id === id,
      )?.name,
  );
  expect(names).toEqual(["Screenshot.png", "Second.png"]);
});

test("a copy pasted back into the same composer brings copies of its attachments by id", async () => {
  recordHost();
  const composer = await openComposer();
  await act(async () => composer.current!.restore(`a ${inlineToken(IMAGE.id)} b`, [IMAGE]));
  await until(() => Boolean(field().querySelector("[data-inline-attachment]")), "the placed attachment");
  await act(async () => markdownField().selectAll());
  const { written } = await clip("copy");
  // Pasted at the end, after the original.
  await act(async () => markdownField().setCaret(markdownField().value().length));
  await pasteBack(written.get("text/plain")!, []);
  await until(() => (composer.current!.wakeState().attachments ?? []).length === 2, "the copy of the image");
  expect(markdownField().value()).toMatch(
    new RegExp(`^a ${MARK}shot${MARK} ba ${MARK}shot%7Ecopy-[0-9a-f]{8}${MARK} b$`),
  );
});

test("pastePlan: only a paste of the remembered copy is put back in order", () => {
  const store = dom.window.localStorage;
  const copy = composerCopy([{ text: "a " }, { id: "x" }, { text: " b" }], false, [{ ...IMAGE, id: "x" }])!;
  const transfer = (plain: string, files: File[]) =>
    ({ files, getData: (type: string) => (type === "text/plain" ? plain : "") }) as unknown as DataTransfer;
  const file = screenshot("Screenshot.png");
  // Before the host answers which files it wrote, files are not known as the copy's.
  rememberCopy(copy, undefined, store);
  expect(pastePlan(transfer("", [file]), () => false, store)).toBeUndefined();
  rememberCopy(copy, ["Screenshot.png"], store);
  // WebKit's paste of file URLs: the files, no text. The text is the copy's.
  expect(pastePlan(transfer("", [file]), () => false, store)).toEqual([{ text: "a " }, { file }, { text: " b" }]);
  // Other files, another count, or another text: not that copy.
  expect(pastePlan(transfer("", [screenshot("other.png")]), () => false, store)).toBeUndefined();
  expect(pastePlan(transfer("", [file, file]), () => false, store)).toBeUndefined();
  expect(pastePlan(transfer("other", [file]), () => false, store)).toBeUndefined();
  // No files: the copy's own text in a composer that still has the attachment, by its id.
  expect(pastePlan(transfer("a  b", []), (id) => id === "x", store)).toEqual([
    { text: "a " },
    { id: "x" },
    { text: " b" },
  ]);
  expect(pastePlan(transfer("a  b", []), () => false, store)).toBeUndefined();
  // A file the host left out is left out of the paste; the text stays.
  rememberCopy(copy, [null], store);
  expect(pastePlan(transfer("a  b", []), () => false, store)).toBeUndefined();
  // A copy of text alone forgets it.
  forgetCopy(store);
  expect(pastePlan(transfer("a  b", []), (id) => id === "x", store)).toBeUndefined();
});

test("composerCopy leaves out an image past what the host writes, never the copy's other attachments", () => {
  const huge = { ...IMAGE, id: "huge", data: "A".repeat(Math.ceil((32 << 20) / 3) * 4 + 4) };
  const copy = composerCopy([{ id: "huge" }, { id: LINK.id }], false, [huge, LINK])!;
  expect(copy.items.map((item) => item.name)).toEqual(["notes.md"]);
});

test("composerCopy: a whole selection carries the strip's attachments before the text's", () => {
  const strip = { ...LINK, id: "strip" };
  const copy = composerCopy([{ text: "a " }, { id: IMAGE.id }], true, [IMAGE, strip])!;
  expect(copy.items.map((item) => item.name)).toEqual(["notes.md", "Screenshot.png"]);
  expect(copy.parts).toEqual([{ item: 0, id: "strip" }, { text: "a " }, { item: 1, id: IMAGE.id }]);
  // Not whole: the strip's stay out.
  expect(composerCopy([{ text: "a " }, { id: IMAGE.id }], false, [IMAGE, strip])!.items).toHaveLength(1);
});
