// Lucas 2026-11-25: "when writing a prompt in a chat that is working and using an image, the image
// seems to disappear randomly." Settings' strip view (the default) draws the attachments in the strip
// alone; each still has its place in the text as a hidden node. The caret sits right after that node
// once the paste lands, so the next Backspace (a typo fixed) took the picture out of the strip and left
// the letter it was pressed for. Backspace and Delete now pass over hidden nodes; the inline view,
// where the chip shows in the text, keeps its Backspace that takes the chip out.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type ComponentProps, type RefObject } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { teardownDom } from "./support/domTeardown";

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
  "KeyboardEvent",
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
    KeyboardEvent: window.KeyboardEvent,
    ...imageEngine(),
  });
  host = window.document.getElementById("root")!;
  // jsdom ranges have no layout; the inline caret (composer/inlineCaret.ts) reads their rects.
  const range = window.Range.prototype as unknown as Record<string, unknown>;
  range.getClientRects ??= () => [];
  range.getBoundingClientRect ??= () => ({
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    width: 0,
    height: 0,
  });
});

afterEach(async () => {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  act(() => settings.setComposerSettings({ attachmentView: "strip" }));
  localStorage.clear();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
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

/// The open composer's handle, for `paste` to read its chips.
let opened: RefObject<ComposerHandle | null> | undefined;

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
  opened = handle;
  const sessionId = newChat ? undefined : `chat-${++composerCount}`;
  const snapshot = noChat(
    [],
    sessionId
      ? {
          sessionId,
          summary: {
            sessionId,
            harness: "codex",
            cwd: "/Users/you/src/app",
            turnCount: 0,
          },
        }
      : {},
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

/// Pastes on the prompt field as WebKit delivers it: one ClipboardEvent with the clipboard's data.
async function paste(clipboard: { files?: File[]; html?: string; plain?: string }) {
  const data = {
    files: clipboard.files ?? [],
    types: [
      ...(clipboard.files?.length ? ["Files"] : []),
      ...(clipboard.html ? ["text/html"] : []),
      ...(clipboard.plain ? ["text/plain"] : []),
    ],
    getData: (type: string) =>
      type === "text/html" ? (clipboard.html ?? "") : type === "text/plain" ? (clipboard.plain ?? "") : "",
  };
  const event = new dom.window.Event("paste", {
    bubbles: true,
    cancelable: true,
  });
  Object.defineProperty(event, "clipboardData", { value: data });
  await act(async () => {
    field().dispatchEvent(event);
  });
  // The chips are read from the files after the event, all of one paste's at once.
  await until(() => (opened!.current!.wakeState().attachments ?? []).length > 0, "the pasted chips");
}

/// Screenshot `index`: its own bytes (the last filler byte), as two different screenshots have.
const screenshot = (index: number) =>
  new File([PNG.slice(0, -1), Uint8Array.of(index)], "image.png", {
    type: "image/png",
    lastModified: index,
  });

const chips = () => opened!.current!.wakeState().attachments ?? [];
const editable = () => host.querySelector<HTMLElement>(".ProseMirror")!;

async function press(key: "Backspace" | "Delete", modifiers: { altKey?: boolean; repeat?: boolean } = {}) {
  await act(async () => {
    editable().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", {
        key,
        code: key,
        bubbles: true,
        cancelable: true,
        ...modifiers,
      }),
    );
  });
}

async function typed(text: string) {
  await act(async () => {
    markdownField().focus();
    markdownField().insertTyped(text);
  });
}

/// The prompt's text with each placed attachment's node written as [image].
const shown = () =>
  markdownField()
    .value()
    .replace(/￼[^￼]*￼/g, "[image]");

async function view(attachmentView: "strip" | "inline") {
  const settings = await import("../src/agent-session/acpmux/composerSettings");
  await act(async () => settings.setComposerSettings({ attachmentView }));
}

test("strip view: Backspace right after a pasted image takes the letter before it, never the image", async () => {
  await openComposer();
  await view("strip");
  await typed("look at thiss");
  await paste({ files: [screenshot(1)] });
  expect(shown()).toBe("look at thiss[image]");
  await press("Backspace");
  expect(shown()).toBe("look at this[image]");
  expect(chips()).toHaveLength(1);
});

test("strip view: Delete just before a pasted image takes the letter after it", async () => {
  await openComposer();
  await view("strip");
  await typed("see ");
  await paste({ files: [screenshot(2)] });
  await typed("xnow");
  await act(async () => markdownField().setCaret(4));
  expect(shown()).toBe("see [image]xnow");
  await press("Delete");
  expect(shown()).toBe("see [image]now");
  expect(chips()).toHaveLength(1);
});

test("strip view: a selection across the image deletes its text and keeps the image", async () => {
  await openComposer();
  await view("strip");
  await typed("keep ");
  await paste({ files: [screenshot(3)] });
  await typed(" drop this");
  // "keep [image] drop this": select from after "keep" through the end, the image's node inside.
  const plain = markdownField().plainText();
  await act(async () => markdownField().writeText(plain, 4, plain.length));
  await press("Backspace");
  expect(shown()).toBe("keep[image]");
  expect(chips()).toHaveLength(1);
});

// Lucas, 2026-11-25: in the strip view Backspace never takes an attachment out, also at the start
// of the prompt (the take-back of backspacedAttachment is the inline view's); only its × does.
test("strip view: Backspace with only the image before the caret keeps it, pressed or held", async () => {
  await openComposer();
  await view("strip");
  await paste({ files: [screenshot(4)] });
  expect(shown()).toBe("[image]");
  await press("Backspace");
  expect(chips()).toHaveLength(1);
  await press("Backspace", { repeat: true });
  expect(chips()).toHaveLength(1);
  expect(shown()).toBe("[image]");
});

test("strip view: Backspace at the start of the prompt takes no image", async () => {
  await openComposer();
  await view("strip");
  await paste({ files: [screenshot(6)] });
  await typed("hi");
  await act(async () => markdownField().setCaret(0));
  await press("Backspace");
  expect(chips()).toHaveLength(1);
  expect(shown()).toBe("[image]hi");
});

test("strip view: Delete at the end of the prompt, before the image, does nothing", async () => {
  await openComposer();
  await view("strip");
  await typed("A");
  await paste({ files: [screenshot(7)] });
  await act(async () => markdownField().setCaret(1));
  await press("Delete");
  await typed("B");
  expect(shown()).toBe("AB[image]");
  expect(chips()).toHaveLength(1);
});

test("inline view: Backspace right after the image's chip takes the chip out, as before", async () => {
  await openComposer();
  await view("inline");
  await typed("look ");
  await paste({ files: [screenshot(5)] });
  await press("Backspace");
  expect(shown()).toBe("look ");
  expect(chips()).toHaveLength(0);
});
